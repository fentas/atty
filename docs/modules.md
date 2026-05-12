---
layout: default
title: Writing a module
---

# Writing a module

A module is a Zig type — typically produced by a
`configure(comptime cfg: Config) type` factory — that exposes some
subset of:

```zig
pub const name: []const u8                          // optional, for logs
pub const Runtime  : type
pub fn   attach    (allocator) !Runtime
pub fn   detach    (rt: *Runtime) void
pub fn   onInput   (rt: *Runtime, ctx: *Context, input: []const u8) !Action
pub fn   onOutput  (rt: *Runtime, ctx: *Context, output: []const u8) !void
pub fn   onTick    (rt: *Runtime, ctx: *Context, elapsed_ms: u64) !void
pub fn   onLineCommit(rt: *Runtime, ctx: *Context, line: []const u8) !void
pub fn   provideGhostText(rt: *Runtime, ctx: *Context) !?[]const u8
```

The framework introspects each module via `@hasDecl` at comptime —
missing hooks are statically eliminated from the dispatch loop, not
merely skipped at runtime.

## Shared types

```zig
pub const Action = union(enum) {
    forward,                    // pass bytes through unchanged
    swallow,                    // drop bytes entirely (short-circuits)
    replace: []const u8,        // substitute these bytes
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    line:      *LineState,      // current user input buffer + uncertain flag
    scratch:   *std.ArrayList(u8),
    is_tty:    bool,
};

pub const Error = error{ ModuleFailed, OutOfMemory };
```

## Minimal example — Upper

Capitalise every keystroke before it reaches the shell:

```zig
const std = @import("std");
const m = @import("../module.zig");

pub const Config = struct {};

pub fn configure(comptime _: Config) type {
    return struct {
        pub const name = "upper";

        pub const Runtime = struct {
            buf: [256]u8 = undefined,
        };

        pub fn attach(_: std.mem.Allocator) !Runtime { return .{}; }
        pub fn detach(_: *Runtime) void {}

        pub fn onInput(
            rt: *Runtime,
            _: *m.Context,
            input: []const u8,
        ) m.Error!m.Action {
            if (input.len > rt.buf.len) return .forward;
            for (input, 0..) |b, i| rt.buf[i] = std.ascii.toUpper(b);
            return .{ .replace = rt.buf[0..input.len] };
        }
    };
}
```

Then in `src/config.zig`:

```zig
const atty = @import("atty");

pub const Upper = @import("modules/upper.zig").configure(.{});
// or if you've placed it inside src/modules/:
//   atty.modules.upper.configure(.{})

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    Upper,
};
```

## Lifecycle

- `attach(allocator)` returns the initial Runtime value. Spawn worker
  threads, open sockets, etc. here. The framework heap-allocates the
  Runtime — you don't need to.
- `detach(rt)` is called once at shutdown. Signal worker threads to
  stop, join them, close sockets.

Allocation: each module's Runtime is heap-allocated by `attachAll`
and freed by `detachAll`. Modules don't manage their own Runtime
allocation.

## Hot-path rules

`onInput` runs on every single keystroke (~100 Hz worst case).
Therefore:

- **No allocations.** Use a fixed-size buffer in your Runtime, or the
  per-dispatch `ctx.scratch`.
- **No blocking I/O.** If you need a network/socket lookup, do it on a
  worker thread and expose the result via `provideGhostText`.
- **No global locks.** Per-Runtime mutexes are fine.

`provideGhostText` runs whenever the proxy needs to refresh the
overlay (after a keystroke, after shell output, on tick). It runs
*after* `onInput` for that event, so `ctx.line.current()` reflects
the post-input buffer.

`onTick` fires on poll() timeout (default 100 ms). Use it for
periodic work — TTL expiry, status updates. Don't do heavy work
here; ticks are not throttled.

## Action semantics

| Returned action | What happens                                          |
|-----------------|-------------------------------------------------------|
| `.forward`      | Bytes flow on to the next module.                     |
| `.swallow`      | Chain stops, nothing is written to the PTY.           |
| `.replace`      | Next modules see the new bytes; PTY writes those.     |

If a module returns `.replace`, downstream modules see the *replaced*
bytes, not the original. This composes guardrail with autosuggestion:
guardrail can swallow Enter, and Atuin never sees the keystroke that
would have submitted a dangerous command.

## Order matters

The dispatcher walks `config.modules` front-to-back. Put
short-circuiting modules (guardrail) first; passive ones (Atuin) last.

For `provideGhostText` the *first non-null* result wins, so order
expresses priority.

## Testing

Write tests inline in your module file. They'll be picked up by
`zig build test` if you add your file to `src/unit_tests.zig`.

```zig
test "my module swallows the dangerous Enter" {
    const M = configure(.{});
    var rt = try M.attach(std.testing.allocator);
    defer M.detach(&rt);

    var line = LineState{};
    _ = line.applyInput("rm -rf /");
    var scratch = std.ArrayList(u8).init(std.testing.allocator);
    defer scratch.deinit();
    var ctx = m.Context{
        .allocator = std.testing.allocator,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    try std.testing.expectEqual(m.Action.swallow, try M.onInput(&rt, &ctx, "\r"));
}
```

See `src/modules/guardrail.zig` for a worked example with an
injectable output sink so tests don't write to stderr.

## Verifying dead-code elimination

The strong claim is that disabled modules contribute nothing to the
binary. Verify it:

```sh
# build with all modules
make build
size=$(stat -c %s zig-out/bin/atty)

# remove a module from config.modules, rebuild
$EDITOR src/config.zig
make build
smaller=$(stat -c %s zig-out/bin/atty)

# check symbols
nm zig-out/bin/atty | grep -c atuin  # should be 0 after removing Atuin
```

If a module's symbols persist after removal, you've found a leak
(probably a forgotten `@import` somewhere) — file an issue.
