---
layout: default
title: FAQ
permalink: /faq/
---

# Frequently asked questions

## What is atty?

A small program that sits between your terminal emulator and your
shell. It watches what you type *before* the shell sees it, so it
can do things like:

- Show ghost-text suggestions from your shell history.
- Warn you (or block you) on dangerous commands like `rm -rf /`.
- Turn `#: list large files` into the actual shell command via an LLM.
- Give you a status bar at the bottom of every terminal.

You see your normal shell. atty is invisible until it has something
useful to say.

## Why would I want this?

You already use a shell. atty layers conveniences on top *without*
making you change shells, learn a new config language, or load a
plugin system.

- **You like your current shell.** atty doesn't replace bash/zsh/fish.
  It runs your shell unchanged, just with extra eyes on it.
- **You want fish-style suggestions in bash/zsh.** Atuin or your
  own history gives you them, atty renders them.
- **You've typed `rm -rf` somewhere scary at least once.** The
  guardrail catches you before Enter lands.
- **You want a status line that survives across terminal emulators.**
  atty's status bar follows you whether you're on Ghostty, Kitty,
  Alacritty, or SSH.

## How is this different from oh-my-zsh / starship / atuin?

| Tool | What it does | Where atty fits |
|---|---|---|
| **starship** | Renders your shell prompt. | Different layer. starship is your PS1; atty sits *outside* your shell. They compose. |
| **oh-my-zsh** | Plugin framework that runs *inside* zsh. | atty is the layer above zsh. You can run oh-my-zsh + atty together. |
| **atuin** | Stores + fuzzy-searches your shell history. | atty's Atuin *module* uses atuin's CLI to surface that history as ghost text in bash AND zsh. atty needs atuin installed for that feature. |
| **fish** | Smart shell with built-in suggestions. | atty gives bash/zsh users the fish-style suggestion + the dangerous-command guard without switching shells. |

You can run atty alongside any of these. None of them does what atty
does.

## Does it slow down my shell?

No. atty's dispatch loop is one `inline for` over the modules you
enabled — every disabled module compiles out completely. There is
no plugin loader, no shared-library lookup at startup, no runtime
config parsing.

In practice: same keystroke-to-display latency as your raw shell, plus
a few microseconds for the suggestion render. The PTY proxy itself is
plain `poll()` on stdin/PTY — no async runtime, no extra threads
unless a module asks for one.

## Where does my config live?

`src/config.zig` in the atty source tree. It's [gitignored][1] so your
edits never conflict on `git pull`.

The companion file `src/config.def.zig` is the template atty ships
with — committed and maintained upstream. On first build, atty copies
it across to `src/config.zig` if you don't have one yet.

If you want your config tracked outside the atty repo (e.g. a dotfiles
repo), point at it with `-Dconfig=/path/to/mine.zig` or
`make CONFIG=/path/to/mine.zig build`.

[1]: https://github.com/fentas/atty/blob/master/.gitignore

## Why edit a file and recompile instead of a runtime config?

This is the Suckless approach — you change the program by changing the
program, then compiling it. The trade-off:

- **Cost**: every config change means a `make build`. Re-running takes
  a few seconds.
- **Win**: every config option becomes part of the type system. Wrong
  module name? Compiler error. Missing field? Compiler error. No
  YAML-parsing-at-startup, no fragile env-var precedence rules.
  Disabled modules don't ship as dead code — they don't ship at all.

If that trade-off is wrong for you, that's totally fair — atty isn't
trying to be everything to everyone. It's a small tool with a
particular point of view.

## Can I disable {Atuin / LLM / security_guard / statusbar}?

Yes. Edit `src/config.zig`, remove the module from `pub const modules`,
recompile. Disabled modules vanish from the binary — no dead code, no
runtime cost.

## I don't have Atuin installed. Will atty still work?

Yes. atty ships with a `history` module (default) that reads
`~/.bash_history` / `~/.zsh_history` directly. No daemon, no shell
plugin. Atuin is opt-in for people who already use it.

## Why is the front-page demo a typing animation and not a real recording?

Because the homepage should still be readable when JavaScript is
disabled — search-engine crawlers, NoScript users, reader-mode
browsers all see the same first frame the animation lands on. A
real `asciinema` cast would be a black box for those readers, and
a video would push the page weight up by an order of magnitude
for very little extra information. The text-driven playback is
honest about what atty is — a terminal program — without trading
accessibility for production value. If the animation isn't moving,
your browser is in a reduced-motion mode (the page honors
`prefers-reduced-motion: reduce`) — the static fallback shows the
same three scenes side by side.

## How do I report a bug?

Open an issue at [github.com/fentas/atty/issues][issues]. Include
the output of `eval "$(atty doctor)"` if your problem is with shell
integration (OSC 133 markers, prompt detection, etc.).

[issues]: https://github.com/fentas/atty/issues

## Is it production-ready?

atty is pre-1.0 — APIs around module hooks may still shift between
minor releases. The PTY core, guardrail, and history modules are
solid. Atuin works for prefix-matched suggestion + record. The LLM
module is opt-in; if you don't enable it, none of its code touches
your shell.

For day-to-day use as a personal shell layer, yes. For shipping it
inside a product, watch the release notes between minor versions.

## Wait — it's written by an LLM?

Mostly, yes. atty's code is primarily LLM-generated and reviewed
through an adversarial loop (an independent model plus a
second-opinion reviewer on every PR) rather than line-by-line by a
human maintainer. The guardrails on that: a large automated test
suite (1,200+ unit tests plus real-PTY integration and
scripted-terminal end-to-end scenarios) gates every change, and CI
cross-compiles and runs it on each PR.

That's a different risk profile than a human-audited tool, and it's
worth being honest about — treat the security features (`guardrail`,
`security_guard`, atty-guard) as defense-in-depth, not a guarantee.
If you're putting atty somewhere that matters, pin a release you've
tested rather than tracking `master`. The code is MIT and on GitHub;
read the parts you care about.

## What's the security_guard module?

It's the in-proc safety net: a handful of statically-compiled
patterns that catch obvious-dangerous shapes (`curl | sh`, `npm
install` of a flagged package, `bash -c <long base64>`, etc.) and
prompt you before the shell runs them.

There's also a much heavier sidecar daemon — `atty-guard` — that
adds a regex tier, an optional ONNX classifier, optional eBPF
kernel-side enforcement, IOC corpus fetching, and a per-user trust
store. That's a separate install (`sudo make install-guard`), and
99% of atty users don't need it. See the [operator workflow
guide][opw] if you want the full stack.

[opw]: /operator-workflow/

## Where do I learn the deep technical stuff?

The architecture, the module-writing guide, the LLM internals, the
security_guard design docs — all on this site under the
"Advanced" section in the nav. They're verbose because the design
decisions need full justifications somewhere, but you don't need to
read any of them to use atty.
