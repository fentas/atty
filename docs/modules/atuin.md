---
layout: default
title: atuin module
permalink: /modules/atuin/
module_default: false
---

# `atuin` module
{:.no_toc}

> **Status:** opt-in. Source: [`src/modules/atuin.zig`](https://github.com/fentas/atty/blob/master/src/modules/atuin.zig)

Fish/zsh-autosuggestion-style ghost text driven by your [Atuin](https://github.com/atuinsh/atuin) history.

* TOC
{:toc}

### How it works

**Suggest path:**

1. Every keystroke updates the line model; `onInput` copies the
   current buffer into the worker's latest-wins query slot and signals.
2. The worker calls `atuin search --search-mode prefix --filter-mode
   global --limit <list_count_max> --cmd-only <query>` (newest match
   wins; no `--reverse` — that flag flips the default and gives the
   *oldest* match instead). `list_count_max` defaults to 9 so the
   inline ghost uses entry 0 and the multi-row pick list
   (`Ctrl+1..9`) consumes the rest.
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
2. The module pushes the line into the worker's **bounded FIFO
   record queue** (`record_queue_capacity` slots; default 16). The
   FIFO preserves commit order across bursts — multi-line paste,
   slow `atuin history start`, or rapid LLM-assisted submits no
   longer overwrite earlier commits. At capacity the producer
   drops the **newest** entry (the oldest is already in flight to
   atuin's local store) and increments `rec_dropped`; the status
   bar surfaces this as `atuin (N dropped)` until detach.
3. The worker drains one record per loop iteration and shells out
   to `atuin history start <cmd>` (we don't capture the entry ID,
   so there's no `history end` — entries land with no exit code
   or duration; atuin handles that gracefully).
4. After `sync_after_records` records or `sync_interval_ms` ms,
   `atuin sync` runs on a **detached** `std.Thread`, so the worker
   never blocks on the network. The clock starts on the first
   record handled rather than at attach, so a session that
   commits no lines never syncs.
5. **Final sync on detach is JOINED** (up to
   `sync_on_detach_timeout_ms`, default 3 s). Worker shutdown
   first drains any queued records, then blocks on the sync thread
   so an interactive session's exit leaves no commits stranded
   locally. The thread is leaked on timeout — bounded shutdown
   beats waiting for atuin's offline backoff.

**Accept path:**

Right-arrow / End / Ctrl-F (configured in `bindings[]`) replace the
keystroke with the current ghost-overlay text before line state sees
the CSI — see the [Keymap](/architecture/#keymap) docs.

### Configuration

```zig
pub const Atuin = atty.modules.atuin.configure(.{
    .backend                    = .subprocess,
    .atuin_binary               = "atuin",
    .socket_path                = "",
    .search_mode                = .prefix,
    .filter_mode                = .global,
    .suggestion_ttl_ms          = 0,
    .max_query                  = 256,
    .max_result                 = 4096,
    .list_count_max             = 9,

    .record                     = true,
    .record_queue_capacity      = 16,
    .sync_after_records         = 10,
    .sync_interval_ms           = 60_000,
    .sync_on_detach             = true,
    .sync_on_detach_timeout_ms  = 3_000,

    .delete_scope               = .exact,
    .tag_llm_author             = false,
    .author_tag_prefix          = "atty",
    .tag_llm_intent             = false,
});
```

| Field                       | Default       | Values                                                       |
|-----------------------------|---------------|--------------------------------------------------------------|
| `backend`                   | `.subprocess` | `.subprocess`, `.socket` (stub)                              |
| `atuin_binary`              | `"atuin"`     | path to atuin executable                                     |
| `socket_path`               | `""`          | path to atuin's IPC socket; consumed only when `backend = .socket` (stub) — ignored otherwise |
| `search_mode`               | `.prefix`     | `.prefix`, `.full_text`, `.fuzzy`                            |
| `filter_mode`               | `.global`     | `.global`, `.host`, `.session`, `.directory`                 |
| `suggestion_ttl_ms`         | 0             | ms of idleness before suggestion fades; 0 disables           |
| `max_query`, `max_result`   | 256 / 4096    | comptime buffer sizes (`max_result` sized for ~9 suggestions) |
| `list_count_max`            | 9             | per-query result cap; entry 0 → ghost text, rest → pick list |
| `record`                    | `true`        | shell out to `atuin history start` on Enter                  |
| `record_queue_capacity`     | 16            | bounded FIFO depth; overflow drops newest + bumps `rec_dropped` |
| `sync_after_records`        | 10            | sync after N records; 0 disables                             |
| `sync_interval_ms`          | 60000         | sync if at least this much time elapsed; 0 disables          |
| `sync_on_detach`            | `true`        | one final sync on shutdown                                   |
| `sync_on_detach_timeout_ms` | 3000          | max ms to wait for the final sync to complete (0 = forever)  |
| `delete_scope`              | `.exact`      | `.exact` / `.prefix` / `.full_text` / `.fuzzy` for Ctrl+Shift+D |
| `tag_llm_author`            | `false`       | tag LLM-authored commits with `--author <prefix>:llm` (atuin v18.3+) |
| `author_tag_prefix`         | `"atty"`      | prefix for the author tag (`<prefix>:llm`)                    |
| `tag_llm_intent`            | `false`       | pass the LLM's intent text via `--intent` (atuin v18.5+)     |

### Backends

- `.subprocess` — shells out to `atuin search`. Robust, used today.
- `.socket` — talks to the Atuin daemon socket. Stub; the symbols are
  wired through `configure` so swapping backends is a one-field
  change once Atuin's IPC protocol stabilises. When `.subprocess` is
  selected, the socket path is comptime-eliminated from the binary,
  and vice versa.

### Status bar segment

Atuin's `statusText` segment is `"atuin"` in the steady state. When
the record FIFO has overflowed during the current session, it
renders `"atuin (N dropped)"` instead, where N is the cumulative
`rec_dropped` counter — gives the operator an at-a-glance signal
that some commits were lost to a burst the worker couldn't drain
in time. The segment is omitted entirely if the user has disabled
the status bar (`statusbar.enabled = false`).

### deleteHistoryMatch

Implemented via `atuin search --search-mode <mode> --delete <query>`.
Atuin v18 has no per-entry-ID delete CLI, and its built-in modes
all over-match for "remove just this line." The implementation
exploits **fuzzy mode's fzf-style anchors** to express true exact
match without the side effects:

All variants share the same `--filter-mode <filter_mode>` argument
(`.global` by default) — omitted from the argv column for brevity:

| `delete_scope` | atuin CLI args | Removes |
|----------------|----------------|---------|
| `.exact` (default) | `--search-mode fuzzy --delete '^<line>$'` | Only commands equal to `<line>` |
| `.prefix` | `--search-mode prefix --delete <line>` | `<line>` and any command starting with it (`echo asd` also removes `echo asdf`) |
| `.full_text` | `--search-mode full-text --delete <line>` | Any command containing `<line>` as a substring |
| `.fuzzy` | `--search-mode fuzzy --delete <line>` | Typo-tolerant fuzzy match; broadest collateral |

Runs synchronously on the proxy thread (single `std.process.run`,
typically <200 ms). Deliberately not routed through the worker
mailbox — the user just pressed a destructive key, the prompt is
already cleared (the proxy sent `Ctrl+U` first), and a brief
blocking window is preferable to a third worker-mailbox slot.

### Performance

- `onInput` does one `memcpy` + a cv-signal, no I/O. Zero allocations.
- The worker thread runs at most one `atuin search` per keystroke
  (coalesced — typing 5 chars quickly results in 1–2 lookups, not 5).
- `provideGhostText` is a mutex+memcpy, no allocations beyond the
  per-dispatch `ctx.scratch`.
