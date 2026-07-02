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
to the report directory and prints the path:

```
[atty debug] report saved: /home/you/.local/share/atty/reports/report-1751000000.json
```

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
(atty never uploads anything). Review a report before sharing it. Incognito
sessions are excluded from recording.

## Roadmap

- **Replay** — feed a report's `in` + `shell` back through atty to regenerate
  `term` and diff it against the recorded output (deterministic repro).
- **Anonymize + convert to a test case** — scrub sensitive tokens and drop a
  report straight into the end-to-end regression suite.
