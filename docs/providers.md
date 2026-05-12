---
layout: default
title: Built-in modules
---

# Built-in modules

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
4. `onTick` expires the suggestion after `suggestion_ttl_ms` of
   keyboard inactivity, so stale offers don't linger.

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
    .suggestion_ttl_ms   = 5_000,
    .max_query           = 256,
    .max_result          = 512,

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
| `suggestion_ttl_ms`    | 5000          | ms of idleness before suggestion expires     |
| `max_query`, `max_result` | 256 / 512  | comptime mailbox sizes                       |
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

1. Match the current line against a configurable rule list (substring
   or prefix).
2. If a rule fires:
   - Swallow the Enter (don't forward to shell).
   - Print a one-line warning banner to stderr.
   - Enter "armed" state.
3. The next Enter passes through.
4. Any non-Enter keystroke disarms (so editing the command doesn't
   accidentally double-press past the guard).

### Default rules

| Name              | Match                  | Reason                            |
|-------------------|------------------------|-----------------------------------|
| `rm-rf-root`      | substring `rm -rf /`   | rm -rf on a root-ish path         |
| `rm-rf-tilde`     | substring `rm -rf ~`   | rm -rf on home                    |
| `dd-raw-device`   | prefix    `dd `        | dd writing to a raw device        |
| `mkfs`            | prefix    `mkfs`       | filesystem creation               |
| `fork-bomb`       | substring `:(){ :\|:& };:` | classic fork bomb             |
| `curl-pipe-sh`    | substring `\| sh`       | curl … \| sh                      |
| `curl-pipe-bash`  | substring `\| bash`     | curl … \| bash                    |
| `chmod-world`     | substring `chmod 777 /`| world-writable root path          |

### Custom rules

```zig
pub const Guardrail = atty.modules.guardrail.configure(.{
    .rules = &.{
        .{
            .name = "git-force-push-main",
            .kind = .{ .substring = "git push --force" },
            .reason = "force-pushing to a shared branch",
        },
    },
});
```

Passing `.rules` replaces the default list entirely; merge manually
if you want both.

### Limitations

- The match runs against our line model, which approximates what the
  user typed. Vi-mode users navigating with `hjkl` flip the buffer
  into `uncertain` state — in that case the guardrail doesn't fire.
  Reasonable default: if we can't tell what the user typed, we don't
  try to second-guess them.
- Substring matches are literal — there's no regex engine. If you
  need one, write a new module; do **not** add it here. A
  pathological regex on the input hot path would be a strict
  regression.
