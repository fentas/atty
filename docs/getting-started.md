---
layout: default
title: Getting started
permalink: /getting-started/
---

# Getting started

Five minutes from "I just heard about atty" to "I'm typing in it." Then
a tour of the things you can turn on once you're comfortable.

## Install

Pick whichever feels right:

### Pre-built binary (fastest)

```sh
curl -fsSL https://bin.atty.sh | sh
```

Detects your CPU, downloads the latest release asset, verifies the
SHA256, drops the binary at `~/.local/bin/atty`. Add `~/.local/bin`
to your `$PATH` if it isn't already.

### Build from source (Suckless way)

```sh
curl -fsSL https://get.atty.sh | sh
```

Same destination, different journey: clones atty into
`~/.local/share/atty/src`, bootstraps Zig 0.16 if you don't have it,
prompts you to look at `src/config.zig`, then compiles and installs.
Use this one if you want to customize.

### Git + make (clone + build)

```sh
git clone https://github.com/fentas/atty.git
cd atty
make build-atty     # → zig-out/bin/atty (musl-static)
make link-atty      # → ~/.local/bin/atty symlinked to the clone
```

Use this when you want to read the source before running it, when
your platform doesn't have a release binary yet, or when you plan
to edit `src/config.zig` and rebuild in place.

> The bare `make build` / `make link` targets also build and link
> the `atty-guard` Rust sidecar (Cargo required). The
> `-atty`-suffixed targets above are the minimal path — Zig only,
> no cargo dependency. See [Security guard](/security-guard/) for
> the daemon flow once you want it.

### Docker

```sh
git clone https://github.com/fentas/atty && cd atty
./scripts/install.sh    # → ./dist/atty
```

## Wire it into your shell

### Option A — shell-rc snippet (recommended)

Drop this in your `.bashrc` or `.zshrc`:

```sh
eval "$(atty init bash)"   # or `atty init zsh`
```

This is the canonical setup. It re-execs the current interactive
shell under atty AND wires up OSC 133 prompt markers — without
those markers, ghost text falls back to keystroke tracking
(best-effort), history capture loses exit-code attribution, and
the LLM module can't tell where one command ends and the next
begins. Set it once in your dotfiles; every new shell picks it up.

### Option B — terminal emulator launches atty

If touching `.bashrc` / `.zshrc` isn't an option (locked-down host,
managed dotfiles, ephemeral container), point your terminal config
at atty directly. For Ghostty (`~/.config/ghostty/config`):

```
command = atty bash
```

For Kitty:

```
shell atty bash
```

Prefer the explicit `atty bash` / `atty zsh` form — when the
terminal emulator spawns atty directly, the environment is minimal
and `$SHELL` may not yet be set.

You'll need to source the OSC 133 snippet yourself for full
accuracy — Option A is still cleaner where it's available.

## First contact

Start a new terminal. You're now inside atty. Try:

```sh
# Type the start of a command you've run before, then watch for the
# dim ghost text at the end of the line. Right-arrow / End / Ctrl+F
# accepts the full suggestion.
git ch                          # → git checkout featu...

# Trip the guardrail without risking any data. `echo … | sh` runs
# a harmless string through a pipe-to-sh — atty intercepts the
# pattern before the shell sees it; the prompt asks for confirm.
# (We deliberately don't suggest typing `rm -rf` to test things —
# if the guardrail isn't engaged for any reason, you lose data.)
echo pipe-execution-test | sh

# Type a prompt-style line with `#:` and an instruction, then
# press Alt+A — atty replaces the line with a shell command,
# Enter runs it. (Bare Enter on `#:` is a no-op by default to
# defend against accidental LLM calls; flip `enter_action` in
# config if you'd rather Enter trigger directly.)
#: list large files in this directory       # Alt+A → du -sh * | sort -h
```

If something's misbehaving, run:

```sh
eval "$(atty doctor)"
```

It prints a colour-coded check of each integration step
(`$ATTY` set, shell detected, OSC 133 functions defined,
`PROMPT_COMMAND` wired, PS1 has the prompt markers, …) and tells you
which step fails when it does.

## Configure it

atty's config is a Zig file. Edit it, recompile, done.

```sh
$EDITOR ~/.local/share/atty/src/src/config.zig
cd ~/.local/share/atty/src && make build
```

The committed template (`src/config.def.zig`) has the full menu with
commented examples. Your edits live in `src/config.zig`, which is
gitignored — `git pull` won't fight you for it. Anything you don't
override falls through to atty's [`defaults.zig`][def].

[def]: https://github.com/fentas/atty/blob/master/src/defaults.zig

A minimal config to get a feel for it:

```zig
const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.history.configure(.{}),  // shell-native ~/.bash_history
};
```

Want Atuin suggestions instead of plain shell history? Swap in:

```zig
pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.atuin.configure(.{}),
    atty.modules.history.configure(.{}),  // fallback when atuin has nothing
};
```

Want a status bar at the bottom of every terminal?

```zig
pub const statusbar: atty.Statusbar = .{ .enabled = true };
```

Want the LLM `#: prompt` flow? See the [LLM module page][llm].

[llm]: /llm/

## What's next?

- The **[FAQ](/faq/)** answers the most common "but what about…"
  questions.
- **[Built-in modules](/providers/)** lists every module that ships
  with atty + its config knobs.
- **[Operator workflow](/operator-workflow/)** is the deep security
  install (atty-guard daemon, eBPF, atom corpus) — only if you want
  the full security stack.
- Under "Advanced" in the nav: architecture deep-dive, how to write
  your own module, the LLM exec-mode design notes.
