---
layout: home
title: atty
permalink: /
---

## Why

Most extensible terminals load plugins from disk: shared libraries,
WASM blobs, scripts. That gives you flexibility but burns startup
latency, smears the type system, and turns config bugs into 2 AM
mysteries.

**atty does the opposite.** Modules are Zig types composed at compile
time. The dispatch loop is one `inline for` over your config tuple —
disabled modules don't ship as dead code, they don't ship at all.

```zig
inline for (config.modules) |M| {
    if (comptime @hasDecl(M, "onInput")) {
        switch (try M.onInput(rt, ctx, input)) {
            .forward => {},
            .swallow => return .swallow,
            .replace => |b| current = b,
        }
    }
}
```

That's the entire hot path. No vtable. No `*anyopaque`. No runtime
branching on the module list. Disable Atuin and every byte of its
worker-thread plumbing vanishes from the binary.

## What's in the box

- **PTY proxy** — low-level POSIX (no libutil), termios raw-mode guard,
  SIGWINCH propagation.
- **Guardrail module** — substring/prefix rules to swallow Enter on
  `rm -rf /`, `dd if=…`, `… | sh`, etc. Confirm with a second Enter.
- **Atuin module** — async worker thread, prefix-matched history
  lookups via the `atuin` CLI, dim/italic ghost text after the
  cursor with TTL-driven fadeout.
- **Module framework** — write your own. Five optional hooks:
  `onInput`, `onOutput`, `provideGhostText`, `onTick`, plus the
  `attach`/`detach` lifecycle.

## Quickstart  {#quickstart}

### Without Zig (Docker)

```sh
git clone https://github.com/fentas/atty
cd atty
./scripts/install.sh        # → ./dist/atty
```

### With Zig

```sh
mise use zig@0.13.0          # or any other way to install Zig 0.13
zig build                    # → ./zig-out/bin/atty
zig build test               # 33 unit tests
zig build itest              # PTY integration test
```

### Make it your shell launcher

Ghostty (`~/.config/ghostty/config`):

```
command = /usr/local/bin/atty
```

Or invoke ad-hoc:

```sh
atty                         # spawns $SHELL through the proxy
atty --shell /bin/bash       # different shell
atty -- -c 'echo hi'         # passthrough args
```

## Configuration

Edit `src/config.zig`. Recompile. That is the entire model.

```zig
const atty = @import("atty");

pub const Guardrail = atty.modules.guardrail.configure(.{
    // .rules = &.{ ... }   // override the defaults if you want
});

pub const Atuin = atty.modules.atuin.configure(.{
    .backend           = .subprocess,
    .search_mode       = .prefix,
    .filter_mode       = .global,
    .suggestion_ttl_ms = 5_000,
});

pub const modules = .{ Guardrail, Atuin };   // order matters
pub const tick_interval_ms: i32 = 100;
```

Want your config tracked in dotfiles? Build with `-Dconfig=/path/to/mine.zig`
(or `make CONFIG=/path/to/mine.zig build`).

## Read on

- [**Architecture**](/architecture/) — module layout, dispatch model,
  termios flag-by-flag rationale, signal handling, ghost-text state
  machine.
- [**Writing a module**](/modules/) — the five hooks, worked Upper
  example, hot-path rules, dead-code-elimination check.
- [**Built-in modules**](/providers/) — Atuin and Guardrail config
  reference.

## Status

`v0.1` — 33 unit tests, 1 integration test, all green. PTY core
production-ready; Atuin subprocess backend works today; daemon socket
stub waiting on upstream IPC stabilisation. License pending. Bugs
welcome at [github.com/fentas/atty](https://github.com/fentas/atty).
