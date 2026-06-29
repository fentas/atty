---
layout: default
title: ttysnap
permalink: /ttysnap/
---

# ttysnap — "Playwright for the terminal"

A small framework for driving a real terminal program under test: send input,
read the **rendered screen** (not just a byte stream), assert against goldens,
record the session, and inject faults — all composed Suckless-style from a
tuple of modules in `config.zig` and baked into a single binary.

Browsers have Playwright/Cypress. TUIs and CLIs have `expect`, `pexpect`, and a
scattering of language-specific helpers — but nothing that combines a **PTY +
a real VT emulator for screen assertions + recording + fault injection** behind
one clean, composable API. This is that, reusing atty's own VT grid.

```sh
zig build ttysnap          # build the configured binary → zig-out/bin/ttysnap
zig build run-ttysnap      # run the example (drives bash, asserts on screen)
zig build test-ttysnap     # run the ttysnap unit tests
```

## Why it exists

Terminal programs are notoriously hard to test: output is an ANSI byte stream,
timing is load-dependent, and "what's on screen" only exists after an emulator
interprets cursor moves, scroll regions, and SGR. The ttysnap answers all three:

- **Real PTY** — the program runs under a pseudo-terminal exactly as it would
  in a user's emulator (controlling tty, `SIGWINCH`, job control, raw input).
- **Real screen** — output is fed to a VT grid (`vt.Grid`), so you assert on the
  *rendered* screen, surviving overwrites/cursor moves/scrolls.
- **Determinism** — auto-waiting primitives (`waitFor`, `waitStable`) replace
  sleeps, and **fault injection is a module**: `fragment_injector` splits reads
  so load-dependent fragmentation races reproduce on every run (this is how
  atty's #525 ghost flake was pinned down and fixed).

## Architecture — the atty way

The ttysnap mirrors atty's composition idiom (`Dispatcher(modules)` for the
proxy, `PanelHost(panels)` for attop):

```
config.zig  ──>  Harness(modules)  ──drives──>  child under a PTY
  (your tuple)     (comptime walk)               │
                                                  └── vt.Grid (rendered screen)
modules ── observe + inject around the lifecycle (resolved by @hasDecl)
```

- **`Harness(modules)`** (`ttysnap.zig`) — the composed driver: spawns the
  child, renders output into a grid, drives input, and fans the lifecycle into
  each module. `Harness(.{})` (empty tuple) is the bare engine. Every hook is
  `@hasDecl`-gated at comptime, so unused hooks cost nothing and deleting a
  module from the tuple removes it from the binary.
- **`module.zig`** — the contract (the hook set; see below).
- **`pty.zig`** — open a master/slave pair, fork, controlled-env `execvpe`.
- **`config.def.zig` → `config.zig`** — the dwm-style template/override split
  (`build.zig` seeds `config.zig`, gitignored). Edit the `modules` tuple,
  recompile — menuconfig, not runtime config.

## The module lifecycle

```
attach            once, right after spawn
beforeRead        before each read — may shrink it (fault injection; ttysnap
                  takes the smallest cap any module asks for)
onOutput          after a chunk is read + fed to the grid (raw bytes)
onFrame           after that chunk — the new screen state
onInput           when the driver sends bytes to the child
onSnapshot        at a named checkpoint (assert / capture); may error to fail
onExit / detach   at teardown
```

Hook shape (all optional except `attach`, each `@hasDecl`-gated):

```zig
pub const Runtime = struct { … }                     // per-module state
pub fn attach(allocator, info: SessionInfo) !Runtime // REQUIRED
pub fn detach(rt: *Runtime) void
pub fn beforeRead(rt: *Runtime, want: usize) usize   // cap ≤ want
pub fn onOutput(rt: *Runtime, bytes: []const u8) void
pub fn onFrame(rt: *Runtime, grid: *const Grid) void
pub fn onInput(rt: *Runtime, bytes: []const u8) void
pub fn onSnapshot(rt: *Runtime, name: []const u8, grid: *const Grid) !void
pub fn onExit(rt: *Runtime, status: u32) void
```

## Writing a module

A parameter-free module is a plain `pub const`; a parameterised one is a
comptime factory returning a type (so you call it in the tuple with its config):

```zig
// modules/byte_counter.zig
const std = @import("std");
const mod = @import("../module.zig");

pub const byte_counter = struct {
    pub const Runtime = struct { total: usize = 0 };
    pub fn attach(_: std.mem.Allocator, _: mod.SessionInfo) !Runtime {
        return .{};
    }
    pub fn onOutput(rt: *Runtime, bytes: []const u8) void {
        rt.total += bytes.len;
    }
};
```

Drop it into the tuple in `config.zig` and recompile:

```zig
pub const modules = .{
    cast_recorder(.{ .path = "run.cast" }),
    @import("modules/byte_counter.zig").byte_counter,
};
```

## Built-in modules

| Module | Hook | Does |
|---|---|---|
| `snapshotter(.{ .dir, .update })` | `onSnapshot` | render the grid → compare to `<dir>/<name>.txt`; on mismatch write `<name>.actual.txt` + fail. `update` (re)writes goldens. |
| `cast_recorder(.{ .path })` | `onOutput`/`onInput` | record an asciinema v2 cast (`asciinema play`, or `agg` → GIF). |
| `fragment_injector(.{ .bytes })` | `beforeRead` | cap each read so escapes split across reads — deterministic fragmentation, no load needed. |
| `latency_injector(.{ .read_ms })` | `beforeRead` | sleep before each read — spread output in time to surface timing races. |
| `resize_injector(.{ .every, .sizes })` | `onOutput` | SIGWINCH storm: resize the child on a cadence (stresses resize handling; leaves the observer grid put — for a grid-tracking resize call `Harness.resize` from the scenario). |
| `gif_recorder(.{ .path, .frame_ms })` | `onFrame` | capture distinct frames → a play-once animated SVG (browser/Inkscape; for a GitHub GIF convert the cast with `agg`). |

## Programmatic API

```zig
const H = ttysnap.Harness(config.modules);
var h = try H.spawn(alloc, .{ .argv = &.{ "vim", "file" }, .cols = 80, .rows = 24, .env = env });
defer h.deinit();

try h.send("ihello\x1b");          // send input (instant)
try h.typeWith("git status", .irregular); // type char-by-char, human cadence
_ = try h.waitFor("hello", 2000);  // auto-wait for it on screen
_ = try h.waitStable(150, 2000);   // settle (no output for 150ms)
if (h.gridContains("ERROR")) { … } // query the rendered screen
try h.snapshot("after_insert");    // fan onSnapshot (golden compare/capture)
try h.resize(100, 30);             // SIGWINCH the child + resize the grid
const status = try h.waitExit(2000);
```

`env` is the **complete** environment (nothing is inherited) so a run is
reproducible across machines.

### Typing cadence

`typeWith` (and the e2e DSL's `type "…" <pattern>`) sends one codepoint at a
time, pumping the inter-key delay so the echo renders per-char and a recording
animates realistic typing. Patterns: `instant` (the default — same as `send`),
`fast`, `consistent`, `slow`, `irregular` (human-like jitter + a beat after
spaces/punctuation), `random`. The jitter is a fixed-seed PRNG, so a recording
regenerates byte-for-byte.

### Demo GIFs

The per-feature docs GIFs are recorded this way: the scenarios in `tests/demo/`
type at `irregular` cadence, and `make demo-gifs` records each as an asciinema
cast then renders it with [`agg`](https://github.com/asciinema/agg) into
`docs/assets/atty-<feature>.gif`. They live outside the regression e2e suite
(they're paced with sleeps), so a feature GIF stays reproducible without
slowing CI.

## Status + roadmap

This is the foundation slice: the engine + the module framework + three modules
+ a working example driving bash, all reusing atty's `vt.Grid`. Deliberately
deferred:

- **VT emulator breadth** — `vt.Grid` is "just enough for atty's tests"; a
  general tool wants fuller scroll-region/alt-screen/wide-char/SGR/mouse
  coverage. This is the main lift to stand alone.
- **More modules** — a GIF recorder (`onFrame`), latency + resize injectors.
- **Folding atty's own e2e harness** (`src/test/e2e`) onto this, removing the
  near-duplicate PTY spawn.
- **ConPTY** for Windows (currently Linux PTY).
