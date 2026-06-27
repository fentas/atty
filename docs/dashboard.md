# atty dashboard (`attop`) — design

> **Status (2026-06): design of record, nothing built yet.** The taxonomy,
> the architecture split, the UX bar, and the metrics API below are the
> agreed plan (converged with the maintainer). No code ships until the
> phasing is started explicitly. Don't re-derive the surface split or the
> Suckless-vs-config tension — they're settled here.

## Why

Everything atty exposes today is power-user surface: `src/config.zig`,
compile-time module composition, eBPF profiles, the atom corpus. A
developer who has never heard of "eBPF" or "PTY proxy" has no way in. **The
dashboard is the accessible face** that makes those internals optional
knowledge — and it is, plausibly, the main selling point for normal users.

North star: *open `attop`, and within 3 seconds know — am I protected, what
is atty doing for me, is everything healthy — and change any of it without
reading a doc.*

## Two surfaces, one binary

Two instincts, both correct, resolve the shape:

- **Don't put it in the proxy.** A full dashboard inside an atty module
  would bloat the hot-path proxy — wrong layer. atty stays lean.
- **Don't ship two binaries.** Jumping between a "setup" TUI and a
  "monitor" TUI to disable the guard / tweak / check status is bad UX.

So: **one standalone binary** (`attop`, the "Grafana"), **plus a thin
opt-in `metrics_exporter` atty module** — the only thing that lives in the
proxy. That resolves both tensions.

```
┌ atty proxy (lean, hot-path) ────────────────┐
│  …modules…                                  │
│  [metrics_exporter]  ← opt-in, compile-time │  atomic counters,
│     Suckless; ONLY emits (no UI, no DB)     │  flushed on onTick
└──────────────────────────────────────────────┘
            │  UDS → atty-guard   (or)  file → $XDG_RUNTIME_DIR/atty/<pid>
            ▼
┌ atty-guard (daemon, optional) ──────────────┐  aggregates the fleet,
│  metrics aggregator + query API             │  per-UID (SO_PEERCRED),
│  (any history/DB lives HERE, never the proxy)│  already exists
└──────────────────────────────────────────────┘
            ▲  query API (UDS)
┌ attop / standalone TUI ─────────────────────┐  install · configure ·
│  one control plane, panels not tools        │  guard status/update ·
└──────────────────────────────────────────────┘  live metrics · fleet
```

**The exporter module only emits** — counters to atty-guard's UDS if the
daemon is present, else a small per-instance file under the runtime dir. No
UI, no DB, no hot-path cost beyond atomic increments + an `onTick` flush.
That keeps it Suckless and keeps "not everyone wants it" true (compile it
in or don't).

**atty-guard is the data hub.** It is already the central, per-UID
(SO_PEERCRED), persistent UDS authority every instance talks to. Fleet
aggregation falls out for free. Any time-series/history store lives here (or
in the TUI), **never in the proxy module** — that's the un-Suckless trap.

## The Suckless / configure tension — menuconfig, not runtime config

atty's whole model is *edit `config.zig`, recompile, done — no runtime
config files.* A TUI that writes runtime config violates that at the root.
The escape hatch is the **Linux `menuconfig` precedent**: it writes
`.config`, then you build. Same move — the dashboard's "configure" is a
**`config.zig` scaffolder**: toggles regenerate the `modules` tuple +
subsystem fields, then it runs `zig build`. Source of truth stays
`config.zig`; compile-time composition is intact. Framed that way it is
legitimately atty; framed as "runtime settings" it is not.

(`atty-guard`'s own `[profile]`/`[enforcement]` TOML is the one runtime
config that already exists — the dashboard's Guard panel edits that via the
existing sudo-mediated CLI, not a new path.)

## UX bar (the differentiators — this is the product)

- **Zero jargon by default.** Never "LSM `bprm_check` → EPERM"; show
  "Kernel protection: On · blocks threats before they run." Jargon lives
  behind an *Advanced* toggle (progressive disclosure).
- **3-second comprehension.** The first screen *is* the answer, not a menu.
- **Safe + reversible.** Every toggle states its consequence in one line;
  dangerous ones (`lockdown`) are gated + explained. Always an undo.
- **Alive, never flickery.** Live metrics, diff-rendered (no full repaints —
  the defensive-rendering discipline the proxy already follows), 4–10 Hz.
- **Keyboard-first *and* discoverable.** Every action has a key *and* a
  visible label — no memorization. Persistent help footer. Mouse optional.
- **Responsive + robust.** Clean at 80×24, scales up; ASCII fallback for
  non-nerd-font terminals; a narrow terminal never breaks the layout.

## Screens (information architecture)

| Panel | What a normal user sees | Behind *Advanced* |
|---|---|---|
| **Home** | protected? what's atty doing? today's value + live feed | raw event stream, latencies |
| **Guard** | a slider `Off → Watch → Block → Lockdown`, each with plain trade-offs; deny-list; "update threat data" | profile internals, eBPF mode, atom corpus, verdicts |
| **AI** | active model, speed; pick a model; try a prompt | providers, endpoints, tokens/cost |
| **Modules** | toggle cards (Autosuggest, Safety rails, AI, Click-to-open…) — one line each + a live "working ✓" dot | the `config.zig` it generates |
| **Fleet** | every atty terminal as a row (dir, running cmd, hit-rate, last seen) + aggregate sparkline | per-instance counters |
| **Setup** | first-run wizard + a health check ("everything's wired ✓") | the `atty doctor` OSC-133 chain |

### Home (the 3-second answer)

```
┌ atty ───────────────────────────────────────── ● Protected ─┐
│                                                              │
│   🛡  Guard     Watching & blocking      kernel: on          │
│   🤖  AI        claude-opus-4 · 240 ms                       │
│   ✨  Suggest   1,204 keystrokes saved today                 │
│                                                              │
│   Today    312 commands · 3 threats blocked · 0 mistakes    │
│            ▁▂▅▇▅▃▂▁▂▄▆█▅▂  activity                          │
│                                                              │
│   Recent                                                     │
│    12:04  ⛔ blocked    curl … | sh   (from deploy.sh)       │
│    12:01  ✦ suggested   git push origin main                │
│    11:58  ✓ allowed     npm install                         │
│                                                              │
├ 5 terminals active ───────────── [g]uard  [a]i  [m]odules  ?┤
└──────────────────────────────────────────────────────────────┘
```

The **Guard slider** is the key normal-user moment: it turns the whole
security-profiles arc (`prompt`/`audit`/`session`/`strict`/`lockdown`/
`smart`) into one comprehensible control with honest per-rung trade-offs
("Block: stops known-bad before it runs; may occasionally stop a tool you
trust — you'll be asked").

## First-run wizard (the onboarding)

`Welcome → detect shell/terminal → install proxy → (optional) turn on the
safety guard [explained] → (optional) pick an AI model → done, here's your
dashboard.` This is what converts "too high-level for normal people" into
"it set itself up and I get it."

## Language

**Zig** for `attop` — reuses atty's existing TUI/style primitives (the
LLM-overlay/pick-list renderer, `ansi.zig`/`style.zig`), is atty-branded,
and is native for the `config.zig` scaffolding. It talks to atty-guard over
the simple JSON-over-UDS protocol below (trivial from Zig). Reuse the
proxy's primitives via a shared lib rather than pulling a heavy TUI
framework (Suckless dep discipline).

## The atty-guard metrics API (data layer)

New UDS request types alongside the existing protocol (`#[serde(tag =
"method", rename_all = "snake_case")]`), all **per-UID gated via
SO_PEERCRED** like the existing `set_threat`/`set_watch` mediated calls
(root sees all UIDs; a non-root caller sees only its own instances).

```jsonc
// instance → daemon (the metrics_exporter module, on each onTick flush)
{ "method": "report_metrics", "pid": 4242, "cwd": "/home/u/proj",
  "shell": "bash", "incognito": false,
  "counters": {                       // monotonic since session start
    "commands": 312, "ghost_accepted": 188, "ghost_shown": 401,
    "keystrokes_saved": 1204, "llm_calls": 7,
    "guard_warn": 2, "guard_block": 1, "guard_refused": 1 },
  "ts_ms": 1750000000000 }
// → { "type": "ok" }

// TUI → daemon: fleet list (this UID's live instances)
{ "method": "list_instances" }
// → { "type": "instances", "instances": [
//      { "pid": 4242, "cwd": "/home/u/proj", "shell": "bash",
//        "last_seen_ms": 1750000000123, "running": "npm install",
//        "counters": { … } }, … ] }

// TUI → daemon: aggregate snapshot (+ guard posture for the Home/Guard panels)
{ "method": "get_metrics" }
// → { "type": "metrics",
//      "aggregate": { "commands": 9123, "threats_blocked": 47, … },
//      "guard": { "profile": "session", "ebpf": "attached",
//                 "enforcement": "one_level", "atoms_version": "2026-06-20",
//                 "deny_rules": { "path": 0, "basename": 3 } },
//      "instances": <count> }
```

- **Privacy stance (non-negotiable for a security tool):** local-only,
  aggregate **counts** — never per-command content. **Incognito-excluded**:
  the exporter mirrors the proxy's `ctx.incognito` gate (it already gates
  recording), so incognito sessions report nothing beyond existence (or
  nothing at all — decide in P1). No data leaves the host.
- **File fallback** (no daemon / proxy-only install): the exporter writes
  `$XDG_RUNTIME_DIR/atty/<pid>.json` (the same `report_metrics` body) +
  a heartbeat ts; the TUI scans the dir for a local fleet view and GCs
  stale files. The TUI prefers the daemon API (true fleet + guard posture),
  falls back to files.
- **No new privilege boundary:** the exporter reports over the *existing*
  group-accessible UDS; the gating is the same SO_PEERCRED model already in
  `server.rs`.

## Phasing (each step ships UX value alone)

1. **P1 — metrics plumbing.** `metrics_exporter` module (atomic counters →
   onTick flush) + the atty-guard `report_metrics`/`get_metrics`/
   `list_instances` API + file fallback. *Foundation — nothing to show
   without data. The profiles arc already produces the guard-posture half
   of the signal.*
2. **P2 — `attop` skeleton + Home.** The 3-second answer. Demo-able MVP.
3. **P3 — Guard panel.** The profile slider + deny-list + "update threat
   data". The security steering, in plain language.
4. **P4 — Fleet overview.** Multi-instance aggregate (the new capability).
5. **P5 — Modules toggle + menuconfig.** `config.zig` scaffold + `zig
   build` with a progress/confirm flow.
6. **P6 — First-run wizard + Setup/doctor + AI panel.**

A jargon-audit + responsive + defensive-render pass runs *through* every
step, not at the end.

## Open questions

- Incognito: report *nothing*, or report existence-only (so the fleet count
  is right) with all counters suppressed? (Lean existence-only.)
- Metrics retention: ephemeral (daemon memory, lost on restart) vs a small
  on-disk ring for history graphs? (Start ephemeral; history is a later
  ask, and it lives in the daemon/TUI, never the proxy.)
- `attop` distribution: separate binary in the same release, or an `atty
  dash` subcommand that execs the separate binary? (Lean separate binary,
  symlinked like `make link`.)

## See also

- `docs/security-profiles.md` — the Guard panel's underlying model.
- `docs/architecture.md` — the proxy + module framework the exporter joins.
- `atty-guard/src/server.rs` — the UDS protocol the metrics API extends.
