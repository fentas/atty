---
layout: home
title: atty
permalink: /
---

## A thin layer on top of your shell

atty sits between your terminal and your shell. It watches what
you type *before* the shell sees it, so you get useful things —
ghost-text suggestions, dangerous-command guardrails, an LLM
`#: prompt → shell command` flow, a status bar that follows you
everywhere — without changing shells or loading a plugin system.

Your shell stays your shell. atty is the layer above.

[Get started in 5 minutes →](/getting-started/)

## What you get

- **Ghost-text suggestions** in bash, zsh — pulled from your shell
  history or from Atuin if you have it. fish-style "press → to
  accept."
- **Guardrail** — `rm -rf /`, `dd if=`, `curl … | sh` shapes get a
  one-key confirmation before they run.
- **`#: prompt` shortcut (opt-in)** — type `#: list large files`,
  press `Alt+A`, atty fills the line with the actual shell command;
  Enter runs it. Works with Ollama, OpenAI, llama.cpp's server,
  anything OpenAI-compatible. (Bare Enter is deliberately a no-op
  so `#:` comments at the prompt don't accidentally call a model;
  set `enter_action = .single` if you want one-key invocation.)
- **Status bar (opt-in)** — DECSTBM-reserved row at the bottom of
  your terminal, with module-contributed segments + a notification
  row for hints + errors.
- **Security guardrails (opt-in, heavy)** — a sidecar daemon with
  regex + ONNX classifier + optional eBPF kernel-side enforcement,
  per-user trust state, IOC corpus from GTFOBins / Sigma. See
  [operator-workflow](/operator-workflow/) if that's your thing.
  Most people don't need it.

## Quickstart

```sh
# Pre-built binary, default modules.
curl -fsSL https://bin.atty.sh | sh
```

That drops atty at `~/.local/bin/atty`. Now point your terminal at
it. For Ghostty (`~/.config/ghostty/config`):

```
command = atty bash
```

Or drop this in your `.bashrc` / `.zshrc`:

```sh
eval "$(atty init bash)"
```

Start a new terminal. Try typing the start of a command you've run
before — the suggestion shows up as dim ghost text. Right-arrow to
accept.

For the full walkthrough — build-from-source path, terminal
emulator tweaks, first config — see
[Getting started](/getting-started/).

## How it's different

| | atty | starship | atuin | oh-my-zsh |
|---|---|---|---|---|
| **Layer** | between terminal and shell | inside shell (prompt only) | inside shell (history) | inside shell (plugin loader) |
| **Affects what you type** | yes — input goes through atty first | no | no | no |
| **Works with bash AND zsh** | yes | yes | yes | zsh only |
| **Compose with the others?** | yes | yes | yes | yes |
| **Plugin system** | compile-time only, no runtime loader | mostly built-in | one-process tool | runtime |

You can run atty alongside starship + atuin + oh-my-zsh. It doesn't
replace any of them.

## Configuration in one screenful

atty's config is a Zig file you edit, then recompile. dwm-style:
ship a sane default template, let users override the bits they care
about, no runtime config parsing.

```zig
const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.atuin.configure(.{}),       // opt-in: needs atuin CLI
    atty.modules.history.configure(.{}),     // fallback shell-native
};

pub const statusbar: atty.Statusbar = .{ .enabled = true };
```

Every subsystem is a struct with per-field defaults — your config
only contains what you override. `git pull` doesn't fight you for
this file (it's gitignored). New tunables added upstream flow in
automatically without you touching anything.

Full config reference is in
[`src/config.def.zig`](https://github.com/fentas/atty/blob/master/src/config.def.zig)
(committed template) +
[`src/defaults.zig`](https://github.com/fentas/atty/blob/master/src/defaults.zig)
(canonical defaults). See [Built-in modules](/providers/) for the
per-module knob list.

## Why compile-time composition?

Most extensible terminals load plugins from disk: shared libraries,
WASM blobs, scripts. That gives you flexibility but burns startup
latency, smears the type system, and turns config bugs into 2 AM
mysteries.

atty's dispatch loop is one `inline for` over your config tuple.
Disabled modules don't ship as dead code — they don't ship at all.
Wrong module name? Compiler error. Missing field? Compiler error.

If you want the full design rationale + a walk through the hot
path, see [Architecture](/architecture/).

## Going further

- **[Getting started](/getting-started/)** — the unhurried install
  + first-config walkthrough.
- **[FAQ](/faq/)** — common questions: why-recompile-to-configure,
  does-it-slow-my-shell, can-I-disable-Atuin, what's-the-security_guard.
- **[Built-in modules](/providers/)** — Atuin, History, Guardrail,
  LLM, security_guard. Each module's config knobs + what each does.
- **[Operator workflow](/operator-workflow/)** — the heavyweight
  security install: atty-guard sidecar daemon, atom corpus, eBPF.

Under "Advanced" in the nav:

- **[Architecture](/architecture/)** — module dispatch, termios
  raw-mode handling, signal flow, ghost-text state machine.
- **[Writing a module](/modules/)** — the lifecycle hooks, a worked
  example, hot-path rules.
- **[LLM exec mode](/llm/)** — the `#: prompt` flow + provider config.

## Status

`v0.1` — unit tests, integration tests, e2e scenario harness, all
green. PTY core production-ready. Atuin records and syncs today.
LLM module ships. The security_guard sidecar is daemon-managed +
permission-gated as of the latest release. MIT-licensed. Bugs and
PRs welcome at
[github.com/fentas/atty](https://github.com/fentas/atty).
