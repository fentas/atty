---
layout: default
title: Built-in modules
---

# Built-in modules

* TOC
{:toc}

## Atuin (`src/modules/atuin.zig`)

Fish/zsh-autosuggestion-style ghost text driven by your [Atuin]
history.

### How it works

**Suggest path:**

1. Every keystroke updates the line model; `onInput` copies the
   current buffer into the worker's one-slot mailbox and signals.
2. The worker calls `atuin search --search-mode prefix --filter-mode
   global --limit 1 --cmd-only <query>` (newest match wins; no
   `--reverse` — that flag flips the default and gives the *oldest*
   match instead).
3. `provideGhostText` reads the latest result under a mutex; if it
   still starts with the current input, the trailing portion is
   rendered after the cursor.
4. `onTick` optionally expires the suggestion after
   `suggestion_ttl_ms` of keyboard inactivity (`0` = disabled,
   suggestion persists until it no longer prefix-matches — fish-style).

**Record path:**

1. `onLineCommit` fires when the user presses Enter on a non-empty,
   certain line (the proxy snapshots the pre-submit buffer from
   `LineState.lastCommitted()`).
2. The module pushes the line into the worker's record mailbox.
3. The worker shells out to `atuin history start <cmd>` (we don't
   capture the entry ID, so there's no `history end` — entries land
   with no exit code or duration; atuin handles that gracefully).
4. After `sync_after_records` records or `sync_interval_ms` ms,
   `atuin sync` runs — on a **detached** `std.Thread`, so the worker
   never blocks on the network. One final sync also runs on detach.

**Accept path:**

Right-arrow / End / Ctrl-F (configured in `bindings[]`) replace the
keystroke with the current ghost-overlay text before line state sees
the CSI — see the [Keymap](/architecture/#keymap) docs.

### Configuration

```zig
pub const Atuin = atty.modules.atuin.configure(.{
    .backend             = .subprocess,
    .atuin_binary        = "atuin",
    .search_mode         = .prefix,
    .filter_mode         = .global,
    .suggestion_ttl_ms   = 0,
    .max_query           = 256,
    .max_result          = 4096,

    .record              = true,
    .sync_after_records  = 10,
    .sync_interval_ms    = 60_000,
    .sync_on_detach      = true,
});
```

| Field                  | Default       | Values                                       |
|------------------------|---------------|----------------------------------------------|
| `backend`              | `.subprocess` | `.subprocess`, `.socket` (stub)              |
| `atuin_binary`         | `"atuin"`     | path to atuin executable                     |
| `search_mode`          | `.prefix`     | `.prefix`, `.full_text`, `.fuzzy`            |
| `filter_mode`          | `.global`     | `.global`, `.host`, `.session`, `.directory` |
| `suggestion_ttl_ms`    | 0             | ms of idleness before suggestion fades; 0 disables |
| `max_query`, `max_result` | 256 / 4096 | comptime mailbox sizes (max_result sized for ~9 newline-separated suggestions) |
| `record`               | `true`        | shell out to `atuin history start` on Enter  |
| `sync_after_records`   | 10            | sync after N records; 0 disables             |
| `sync_interval_ms`     | 60000         | sync if at least this much time elapsed; 0 disables |
| `sync_on_detach`       | `true`        | one last sync on shutdown                    |

### Backends

- `.subprocess` — shells out to `atuin search`. Robust, used today.
- `.socket` — talks to the Atuin daemon socket. Stub; the symbols are
  wired through `configure` so swapping backends is a one-field
  change once Atuin's IPC protocol stabilises. When `.subprocess` is
  selected, the socket path is comptime-eliminated from the binary,
  and vice versa.

### Status bar segment

Atuin contributes `"atuin"` as its `statusText` segment (always-on
label). Future iterations will surface queued-record count and
last-sync age. The segment is omitted entirely if the user has
disabled the status bar (`statusbar.enabled = false`).

### deleteHistoryMatch

Not implemented — `atuin history delete` needs an entry ID, and atty
doesn't capture IDs at record time (one CLI call per commit, not
two). If you need to delete from atuin's store, do it via the CLI
directly. The `delete_history_match` action still affects the
`history` module if you have both wired in your `modules` tuple.

### Performance

- `onInput` does one `memcpy` + a cv-signal, no I/O. Zero allocations.
- The worker thread runs at most one `atuin search` per keystroke
  (coalesced — typing 5 chars quickly results in 1–2 lookups, not 5).
- `provideGhostText` is a mutex+memcpy, no allocations beyond the
  per-dispatch `ctx.scratch`.

[Atuin]: https://github.com/atuinsh/atuin

---

## Guardrail (`src/modules/guardrail.zig`)

Confirmation prompt for dangerous commands.

### How it works

When the user presses Enter:

1. Match the current line against a configurable rule list. Each rule
   carries a `Match` (substring / prefix / glob), an `AuthorMask`
   (user / llm gate), and a `Behavior` (`.confirm`, `.confirm_once`,
   `.block`, `.warn`).
2. First matching rule wins, in declaration order.
3. `.confirm` swallows the Enter, prints a banner, enters "armed"
   state. Next Enter passes through; non-Enter keystroke disarms.
4. `.confirm_once` works like `.confirm` but the confirmation
   persists for the rest of the session (per rule).
5. `.block` replaces the Enter with Ctrl+U (clears the typed line)
   and prints a banner; the command can never run.
6. `.warn` prints a banner and forwards the Enter — useful when you
   want an audit trail without friction.

The banner tags the author: `atty guardrail: <reason> [user|llm]`.

### Default rules

Author-aware: model-suggested destructive commands are stricter than
user-typed ones. The exact root-path `rm -rf /` and the classic fork
bomb are `.block` for both authors. Most others differentiate:

| Pattern                       | User behavior | LLM behavior |
|-------------------------------|---------------|--------------|
| `rm -rf /` (exact glob)       | `.block`      | `.block`     |
| `:(){ :&#124;:& };:` (substring) | `.block`   | `.block`     |
| `rm -rf ~` (substring)        | `.confirm`    | `.block`     |
| `rm -rf` (substring)          | `.confirm`    | `.block`     |
| `sudo mkfs` (prefix)          | `.confirm` †  | `.block`     |
| `sudo dd ` (prefix)           | `.confirm` †  | `.block`     |
| `sudo ` (prefix)              | `.confirm`    | `.confirm`   |
| `mkfs` (prefix)               | `.confirm`    | `.block`     |
| `dd ` (prefix)                | `.confirm`    | `.block`     |
| `&#124; sh` (substring)       | `.confirm`    | `.confirm`   |
| `&#124; bash` (substring)     | `.confirm`    | `.confirm`   |
| `chmod 777 /` (substring)     | `.confirm`    | `.confirm`   |

† User-typed `sudo mkfs …` / `sudo dd …` match the explicit user rules
no earlier than the generic `sudo` rule (which also `.confirm`s), so
the visible behavior is the same; the explicit `sudo-mkfs-llm` /
`sudo-dd-llm` rules exist to shadow the generic `sudo` rule for the
LLM path under first-match-wins ordering.

### Custom rules

Two knobs:

- **`extra_rules`** — your rules are *prepended* to whatever
  `rules` resolves to (defaults to the shipped `default_rules`).
  Under first-match-wins your entries check first, so this is the
  right place to declare stricter overrides (`.block` a pattern the
  defaults only `.confirm`) or whitelists (a `.warn` rule that
  matches before the default `.block` would). Empty default = use
  `rules` only. **Use this for the common "I just want to add a
  couple more rules" case.**
- **`rules`** — full replacement list. Defaults to the shipped
  `default_rules`. Set this when you want a minimal custom policy
  tailored to your environment and explicitly *not* the defaults.
  Setting both `rules` and `extra_rules` is supported (extras
  prepend to your custom list).

```zig
// Common case: extend the defaults.
pub const Guardrail = atty.modules.guardrail.configure(.{
    .extra_rules = &.{
        .{
            // user-only — without the explicit mask this would also
            // match llm-authored commits, and because first-match
            // wins, the llm-only block below would be unreachable.
            .name = "git-force-push-user",
            .match = .{ .substring = "git push --force" },
            .reason = "force-pushing to a shared branch",
            .authors = .{ .user = true, .llm = false },
            .behavior = .confirm_once,
        },
        .{
            .name = "git-force-push-llm",
            .match = .{ .substring = "git push --force" },
            .reason = "force-pushing (llm)",
            .authors = .{ .user = false, .llm = true },
            .behavior = .block,
        },
    },
    .warning_style = atty.style.presets.danger,   // bold red
});

// Rare case: replace defaults entirely.
pub const MinimalGuardrail = atty.modules.guardrail.configure(.{
    .rules = &.{
        .{ .name = "rm-rf-root",
           .match = .{ .glob = "rm -rf /" },
           .reason = "rm -rf on root",
           .behavior = .block },
    },
});
```

`warning_style` takes an `atty.Style` — same type the ghost overlay
uses, so a single palette can drive the whole proxy. Default style
is `.{ .dim = true, .italic = true }`.

### Limitations

- The match runs against our line model, which approximates what
  the user typed. **Vi-mode `hjkl` navigation desyncs the model
  silently** — atty doesn't see the vi-mode/insert-mode distinction
  on stdin (`hjkl` are plain printable bytes), so the line model
  appends them while the shell's readline treats them as cursor
  moves and emits `\x1b[D` / `\x1b[B` / `\x1b[A` / `\x1b[C` back
  through the master fd. OSC 133 sync doesn't recover this either
  because the `syncFromCapture` gate requires either the line
  model to be `uncertain` or the captured input to be at least
  as long as the model — neither holds in this case.
  Practical consequence: in vi-normal navigation, the guardrail's
  matcher reads a partially-wrong buffer; pathological typed
  content (substring matching a tripwire pattern that the user
  never actually executed) could trigger a false positive on
  Enter. The conservative fix would be probing `set -o` at attach
  to detect vi-mode + short-circuit guardrail there; currently
  it's a documented edge case.
- Substring matches are literal — there's no regex engine. If you
  need one, write a new module; do **not** add it here. A
  pathological regex on the input hot path would be a strict
  regression.

---

## History (`src/modules/history.zig`)

Shell-native command history with fish-style ghost suggestions —
no daemon, no shell plugin. Reads and writes the file your shell
already uses (`~/.bash_history`, `~/.zsh_history`, `~/.history`),
so commands typed through atty are visible to everything else
that reads the file (and vice-versa).

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
