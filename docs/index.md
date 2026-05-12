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
- **History module** *(default)* — shell-native; reads + writes the
  same `~/.bash_history` / `~/.zsh_history` your shell uses. No
  daemon, no shell plugin, no external dependency.
- **Atuin module** *(opt-in)* — async worker thread, prefix-matched
  history lookups via the `atuin` CLI, recording on Enter,
  detached-thread `atuin sync`. Enable in `config.zig` if you have
  atuin installed.
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

dwm-style two-file split:

- [`src/config.def.zig`](https://github.com/fentas/atty/blob/master/src/config.def.zig) — committed template with commented examples (atty maintains this).
- **`src/config.zig`** — your file. Gitignored. `build.zig` copies the template across on first build if it's missing.
- [`src/defaults.zig`](https://github.com/fentas/atty/blob/master/src/defaults.zig) — atty-shipped value for every knob.

Edit `src/config.zig`. Recompile. Your edits never conflict on `git pull`
because the file isn't tracked, and your config only contains what you
override — every other knob falls through to `defaults.zig`, so new
tunables added upstream just appear without you touching anything.

```zig
const atty = @import("atty");

// Pick your modules. Default = { guardrail, history } — dependency-free.
pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.atuin.configure(.{
        .suggestion_ttl_ms  = 0,          // 0 = fish-style (no fade)
        .sync_after_records = 10,
    }),
    atty.modules.history.configure(.{}),  // shell-native fallback
};

// Override the visual style if you don't want the dim-only default.
pub const ghost: atty.Ghost = .{ .style = atty.style.presets.muted_italic };

// Override the accept keys if Right / End / Ctrl+F isn't what you want.
pub const keymap: atty.Keymap = .{
    .bindings = &.{
        .{ .bytes = atty.keymap.key("Tab"), .action = .ghost_accept },
    },
};
```

Every subsystem (`proxy`, `ghost`, `terminal`, `keymap`, `statusbar`)
is a struct with per-field defaults — your `pub const xxx: atty.Xxx = .{ … }`
only spells out the fields you want different. Anything you don't
declare picks up `defaults.zig`, and new fields added upstream flow
through automatically.

Track your config outside the repo: `-Dconfig=/path/to/mine.zig`
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
