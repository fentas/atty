---
layout: default
title: Debugging / feedback capture
permalink: /debugging/
---

# Debugging / feedback capture
{:.no_toc}

atty can record the recent window of terminal I/O in memory and, on a keystroke,
dump it to a self-contained report — so a ghost-text, LLM, or **render-artifact**
bug (atty mangling the shell's output) can be captured the moment it happens and
reproduced later.

* TOC
{:toc}

## Enable it

Off by default — recording keystrokes and output is sensitive, so it's opt-in.
In `src/config.zig`:

```zig
pub const debug: atty.Debug = .{
    .enabled = true,
    .ring_bytes = 256 * 1024, // one half of the in-memory double buffer
    .report_dir = "",         // "" → $XDG_DATA_HOME/atty/reports (or ~/.local/share/…)
};
```

Recompile (`make build`) and run atty as usual.

## Capture

When something looks wrong, press **`Alt+Shift+D`**. atty writes a JSON report
to the report directory and shows the path in the status bar's hint row (just
above the footer), so repeated captures don't pile up in your scrollback:

```
atty debug: report saved → /home/you/.local/share/atty/reports/report-1751000000-123456789.json
```

With no status bar configured — or with hints disabled (`statusbar.hint_ttl_ms
= 0`) — the same message is printed inline instead.

Nothing is written to disk until you press it — the recorder is a bounded
**in-memory** ring, so there is no passive log sitting around to leak.

## What's in a report

Three timestamped byte streams for the recent window (1–2× `ring_bytes`):

| stream  | what it is                                                        |
|---------|-------------------------------------------------------------------|
| `in`    | keystrokes atty received (stdin)                                  |
| `shell` | the raw bytes the shell produced (atty's *input*)                 |
| `term`  | atty's final bytes to the terminal — **including its own** status bar / ghost / overlay injections |

Plus context: atty version, terminal size, `TERM` / `SHELL` / `LANG`, the
current line-editing state, and whether incognito was on.

Having `shell` and `term` side by side is the point: you can see exactly what
atty did to the shell's output — where an overlay was injected, where a render
fragment or stray escape crept in — which is what makes debugging atty itself
(not just modules) possible.

## Privacy

The streams contain your commands and their output. Reports stay **local**
(atty never uploads anything). Review a report before sharing it.

- **Incognito** sessions are excluded from recording.
- **Password entry** (sudo / ssh / passwd / `read -s` — any time the child turns
  echo off) is excluded from the `in` stream, so typed passwords are never
  recorded.
- Per-command `subprocess.incognito_targets` (a *history-persistence* exclusion)
  is **not** applied to this ephemeral debug window — review a report before
  sharing if you rely on it. Phase 3 (anonymization) will scrub such material.

## Limitations

- The `term` stream captures atty's writes through its main output path. A few
  one-time control sequences (kitty-keyboard / mouse enable at startup) and some
  module-direct writes bypass that path and aren't teed.

## Replay

Re-see a captured session (or bug) from a report:

```sh
atty debug replay report-1751000000-123456789.json
```

By default it replays the `term` stream — exactly the bytes atty wrote to the
terminal, with the recorded timing — so a render artifact reappears the way it
happened. Options:

| flag              | effect                                                    |
|-------------------|-----------------------------------------------------------|
| `--stream <name>` | replay `in`, `shell`, or `term` (default `term`)          |
| `--fast`          | skip the inter-event delays and dump instantly            |
| `--info`          | print a summary (version, size, per-stream counts) instead|

Replaying `--stream shell` shows what the shell produced *without* atty, so
comparing it against the default `term` replay reveals atty's transformation.
The replay is byte-exact: the report's `\u00XX`-encoded stream data decodes back
to the original raw bytes.

## Anonymize + share

Before handing a report to anyone, scrub it:

```sh
atty debug anonymize report-….json > report.clean.json
```

The scrubber (pure, regex-free) applies:

| kind          | rule                                                        |
|---------------|-------------------------------------------------------------|
| `$HOME`       | your home path → `~`                                         |
| `$USER`       | your username → `USER`                                       |
| `$HOSTNAME`   | your hostname → `HOST`                                       |
| emails        | `a@b.tld` → `[EMAIL]`                                        |
| IPv4          | `d.d.d.d` → `[IP]`                                           |
| tokens / JWTs | `eyJ…` and long base64/hex runs (≥20 chars) → `[REDACTED]`   |

The result is still a valid report you can `atty debug replay`. This is what
closes the per-command `subprocess.incognito_targets` gap for the ephemeral
debug window — anonymize covers the sharing path even for material the recorder
itself doesn't exclude. **Still review the output before sharing** — the
scrubber is best-effort, not a guarantee.

To share a *visual* recording instead, export a scrubbed
[asciinema](https://asciinema.org) cast of a stream:

```sh
atty debug to-cast report-….json > bug.cast        # the `term` stream
atty debug to-cast report-….json --stream shell    # or another stream
```

`bug.cast` plays in any asciinema player (or renders to a GIF with `agg`).

## Roadmap

- **Convert a report into a runnable regression test** — replay it through
  atty's output pipeline offline and diff the resulting screen. Needs a
  production VT model (the same one a grid-diff replay would use); not yet built.
