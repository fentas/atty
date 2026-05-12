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
  cursor, recording on Enter, detached-thread `atuin sync`.
- **History module** — shell-native fallback that reads + writes
  the same `~/.bash_history` / `~/.zsh_history` your shell uses,
  no daemon, no shell plugin. Composes with Atuin as a backup
  suggestion source.
- **Keymap** — dwm-style `bindings[]` of `{ bytes, action }` pairs;
  ships with right-arrow / End / Ctrl-F bound to `ghost_accept` so
  fish-style suggestions can be accepted with one keypress.
- **Module framework** — write your own. Six optional hooks:
  `onInput`, `onOutput`, `provideGhostText`, `onTick`, `onLineCommit`,
  plus the `attach`/`detach` lifecycle.

## Quickstart  {#quickstart}

### One-line install — pick your philosophy

```sh
# 🛠  Suckless way — clone source, edit config, compile.
curl -fsSL https://get.atty.sh | sh

# 📦 Pre-built binary, default modules.
curl -fsSL https://bin.atty.sh | sh
```

| Path              | What it does                                                                            |
|-------------------|-----------------------------------------------------------------------------------------|
| `get.atty.sh`     | Bootstraps Zig if missing → clones to `~/.local/share/atty/src` → prompts to edit `src/config.zig` → builds → installs |
| `bin.atty.sh`     | Detects arch → downloads release asset → sha256 verify → installs                       |

Both end up at `~/.local/bin/atty` by default; pass `INSTALL_DIR=…`
to override. The source installer also honors `ATTY_SRC=…`,
`ATTY_NONINTERACTIVE=1`, and `REPO_URL=…` so you can fork and
self-host.

### Or via Docker

```sh
git clone https://github.com/fentas/atty
cd atty
./scripts/install.sh        # → ./dist/atty
```

### With Zig

```sh
mise use zig@0.16.0          # or any other way to install Zig 0.16
zig build                    # → ./zig-out/bin/atty
zig build test               # 33 unit tests
zig build itest              # PTY integration test
```

### Make it your shell launcher

Ghostty (`~/.config/ghostty/config`):

```
# Ghostty starts atty, which then starts your shell.
command = atty bash
```

Prefer the explicit form (`atty bash`/`atty zsh`/…) over relying on
`$SHELL` — when the terminal emulator spawns atty directly, the
environment is minimal and `$SHELL` may not yet be set.

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
    .backend             = .subprocess,
    .search_mode         = .prefix,
    .filter_mode         = .global,
    .suggestion_ttl_ms   = 0,            // 0 = no fadeout (fish-style)
    .record              = true,         // record on Enter via `atuin history start`
    .sync_after_records  = 10,           // 0 = disable count-based sync
    .sync_interval_ms    = 60_000,       // 0 = disable time-based sync
});

pub const modules = .{ Guardrail, Atuin };   // order matters
pub const tick_interval_ms: i32 = 100;

// Visual styling — atty.Style is the shared primitive every visible
// module accepts (ghost overlay, guardrail warning, …). Presets in
// atty.style.presets; or write Style literals inline.
pub const ghost_style: atty.Style = atty.style.presets.muted;

// dwm-style key bindings. Use atty.keymap.key("Right") for readability;
// the helper resolves at compile time, so typos break the build.
pub const bindings: []const atty.keymap.Binding = &.{
    .{ .bytes = atty.keymap.key("Right"),  .action = .ghost_accept },
    .{ .bytes = atty.keymap.key("End"),    .action = .ghost_accept },
    .{ .bytes = atty.keymap.key("Ctrl+F"), .action = .ghost_accept },
};
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

`v0.1` — unit tests, integration test, e2e scenario harness with
visual grid diff, all green. PTY core production-ready; Atuin
subprocess backend records and syncs today; daemon socket stub
waiting on upstream IPC stabilisation. MIT-licensed. Bugs welcome at
[github.com/fentas/atty](https://github.com/fentas/atty).
