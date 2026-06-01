---
layout: default
title: history module
permalink: /modules/history/
module_default: true
---

# `history` module
{:.no_toc}

> **Status:** enabled by default. Source: [`src/modules/history.zig`](https://github.com/fentas/atty/blob/master/src/modules/history.zig)

Shell-native command history with fish-style ghost suggestions — no daemon, no shell plugin. Reads and writes the file your shell already uses (`~/.bash_history`, `~/.zsh_history`, `~/.history`), so commands typed through atty are visible to everything else that reads the file (and vice-versa).

* TOC
{:toc}

### How it works

**Init.** Resolves the history file from `$HISTFILE` if set,
otherwise `~/.zsh_history` / `~/.bash_history` / `~/.history`
based on `$SHELL`. Reads the tail (up to 1 MiB) and loads the
most recent `capacity` entries into a ring kept in memory.

**Record.** `onLineCommit` appends each committed line to the
history file via a single atomic `O_APPEND` write (≤ PIPE_BUF =
4096 B; `max_line` caps lines below that). The line also goes
into the in-memory ring, evicting the oldest entry if at capacity.
For zsh the extended-history prefix `: <unix_ts>:0;` is prepended;
bash and others get a bare line.

**Suggest.** `provideGhostText` walks the ring newest-first and
returns the first entry that prefix-matches the current input.

### Composing with Atuin

Put `History` *after* `Atuin` in `config.modules`:

```zig
pub const modules = .{ Guardrail, Atuin, History };
```

`provideGhostText` is "first non-null wins" across modules — atuin
gets to suggest first, history fills the gap when atuin is empty,
not installed, or hasn't synced recently.

### Configuration

```zig
pub const History = atty.modules.history.configure(.{
    .path               = "",         // "" = auto-detect from $HISTFILE / $SHELL
    .format             = .auto,      // .auto, .bash, .zsh_extended, .plain
    .record             = true,
    .suggest            = true,
    .capacity           = 5_000,
    .max_line           = 4_096,
    .suggestion_ttl_ms  = 5_000,
    .match              = .prefix,    // .substring is reserved for later
});
```

| Field                  | Default       | Notes                                                  |
|------------------------|---------------|--------------------------------------------------------|
| `path`                 | `""`          | `""` auto-detects from `$HISTFILE` then `$SHELL`       |
| `format`               | `.auto`       | `.bash`, `.zsh_extended`, `.plain`                     |
| `record`               | `true`        | Append on Enter                                        |
| `suggest`              | `true`        | Serve ghost-text suggestions                           |
| `capacity`             | 5000          | Ring size; oldest evicted past this                    |
| `max_line`             | 4096          | Anything longer is dropped (likely pasted garbage)     |
| `suggestion_ttl_ms`    | 5000          | TTL on cached ghost match                              |
| `match`                | `.prefix`     | `.substring` not yet wired                             |

### deleteHistoryMatch

Implements the optional `deleteHistoryMatch` hook. When the user
fires `Action.delete_history_match` (default `Ctrl+Shift+D`) with the
target line in their buffer, the module:

  1. Walks the in-memory ring and removes every entry whose payload
     equals the line — duplicates included.
  2. Rewrites the on-disk history file via the temp + rename trick
     so a crash mid-write can't corrupt the existing file.

Errors are swallowed: a read-only or missing parent directory means
the ring stays filtered in this session but the file isn't updated.

### Limitations

- **No exit-code tracking.** Records fire on Enter, before the
  shell completes the command. Atuin's official shell plugin uses
  `PROMPT_COMMAND` for that; we don't. Entries land in the file with
  no exit code attached (bash format has no slot for one; zsh
  extended-history's duration field is set to `0`).
- **Tab completion isn't followed on shells without OSC 133.**
  Without prompt markers, atty's line model can't tell a
  Tab-completed line from the typed prefix it expanded from —
  falls back to the keystroke buffer, which still reads the
  pre-Tab text. With OSC 133 markers active (the default after
  `eval "$(atty init bash)"` / `eval "$(atty init zsh)"`), the
  marker stream's `;B` echoes the completed input region and atty
  re-syncs the line buffer from it. See
  [OSC 133 prompt markers](/architecture/#osc-133-prompt-markers-auto-detect)
  for the wider integration story and
  [line-state model](/architecture/#line-state-model) for the
  underlying state machine.
- **Substring-mode ghost** isn't implemented yet — the ghost renderer
  only paints the tail past the query position, which is wrong for
  non-prefix hits. Set `.match = .prefix` (the default).
