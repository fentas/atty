---
layout: default
title: Dashboard (attop)
permalink: /dashboard/
---

# The atty dashboard (`attop`)

`attop` is the dashboard — *the Grafana of atty*: am I protected? what is atty
doing for me? is everything wired up? It's a standalone binary that reads the
`atty-guard` daemon and reuses atty's render primitives. Install it with:

```sh
curl -fsSL https://tui.atty.sh | sh    # → ~/.local/bin/attop
```

Run `attop`. It opens on a **setup wizard** that detects what's installed and
walks you through the rest — installing atty, wiring your shell (with your
consent), enabling the daemon — and shows what's compiled in and configured.
From a clone: `zig build attop` builds it, `zig build run-attop` runs it in
place. See [Getting started]({{ '/getting-started/' | relative_url }}) for the install walkthrough.

The rest of this page is the **design of record** — the architecture split, UX
bar, screens, metrics API, theming/i18n, and phasing. The interactive core is
now **shipped** (see Status + *Writing a panel*); the `[locked]` markers record
decisions ratified before building that still hold.

> **Status (2026-06): design ratified + the interactive core SHIPPED.** The
> panel framework, keyboard navigation, selectable/scrollable lists, detail
> views, `/`-search, and flicker-free diff rendering are built (next section).
> The architecture split, UX bar, screens, metrics API, and theming/i18n below
> are the agreed design; don't re-derive the surface split or the
> Suckless-vs-config tension — settled here.

## Status — shipped vs planned (2026-06)

The rest of this doc is the plan; this section tracks what's **built** on
`master`.

**Shipped:**

- **P1 — metrics plumbing.** The opt-in `metrics_exporter` module + the
  atty-guard metrics API (`report_metrics` / `get_metrics` / `list_instances`,
  per-UID gated).
- **P2 — `attop` + the UI foundation.** The standalone binary (`zig build
  attop` to install, `run-attop` to run in place) with **Home / Guard / Fleet
  / Setup** screens, responsive
  layout, **theming** (dark / light / high-contrast / mono / ascii; `NO_COLOR`
  + `COLORFGBG` aware), **i18n** (en + de, `$ATTOP_LANG`-driven), and
  **screenshot-verified** rendering (each screen fed through the VT grid).
- **Profile switch.** Live `prompt → … → strict` switching: atty's `Alt+P`
  (per `security_guard.profile_switch_mode` — default `.sudo` stages the
  `sudo atty-guard profile set` command) or that command directly.
- **Capability wizard + UI install.** `attop` ships as its own installable
  binary — `curl -fsSL https://tui.atty.sh | sh` (or `zig build attop` from
  source). It opens **capability-aware**: the Setup/wizard when atty isn't
  installed or the daemon is unreachable, else Home. **Setup** is a live
  checklist — atty installed, shell wired, atty-guard running, security
  profile, eBPF + enforcement depth, the daemon's compiled-in features,
  sessions reporting, in-atty — each failing/optional row with a one-line fix.
  Pressing **`[w]`** on a not-wired shell does a **consented** integration
  write (see "First-run wizard"). **Home** is honest when no session reports
  metrics (says so rather than showing zeros).
- **Interactive, panel-extensible TUI** (the UX-bar + Extensibility design,
  now built). Screens are **panels** — a comptime tuple in
  `src/attop/config.zig`, walked like the proxy's modules (see *Writing a
  panel*). Real keyboard nav (Tab / Shift+Tab / arrows / the `[h][g][f][s][?]`
  hotkeys), the focused panel sees each key first, render-on-keystroke (no
  input lag), and **synchronized-output, diff-rendered** frames — only changed
  rows repaint, so it never flickers. **Fleet** is a selectable, scrollable
  session list with Enter-to-open detail and `/`-search; **Guard** is a
  browsable rung list. Add a panel by dropping a struct into the tuple.

**Planned (not yet built):** the AI panel's productivity counters, Alerts
(system notification + webhook hooks), `menuconfig` (`config.zig` scaffold),
and optional polish — mouse (click a tab / row), responsive multi-column at
≥120 cols, i18n of the tab titles. Guard's profile switch stays on atty's
`Alt+P` / `sudo atty-guard profile set` (wiring it into the Guard panel is a
future step); Setup's `[w]` shell-integration write remains the one mutating
action (consented).

## Why

Everything atty exposes today is power-user surface: `src/config.zig`,
compile-time module composition, eBPF profiles, the atom corpus. A
developer who has never heard of "eBPF" or "PTY proxy" has no way in. **The
dashboard is the accessible face** — plausibly the main selling point for
normal users.

North star: *open `attop`, and within 3 seconds know — am I protected, what
is atty doing for me, is everything healthy — and change any of it without
reading a doc.*

## Two surfaces, one binary [locked]

- **Not in the proxy.** A full dashboard inside an atty module bloats the
  hot-path proxy — wrong layer. atty stays lean.
- **Not two binaries.** Jumping between a "setup" TUI and a "monitor" TUI
  is bad UX.

So: **one standalone binary `attop`** (the "Grafana") + **a thin opt-in
`metrics_exporter` atty module** — the only proxy-side piece.

```
┌ atty proxy (lean, hot-path) ────────────────┐
│  …modules…                                  │
│  [metrics_exporter]  ← opt-in, compile-time │  atomic counters,
│     Suckless; ONLY emits (no UI, no DB)     │  flushed on onTick
└──────────────────────────────────────────────┘
            │  UDS → atty-guard   (or)  file → $XDG_RUNTIME_DIR/atty/<pid>
            ▼
┌ atty-guard (daemon, optional) ──────────────┐  aggregates the fleet,
│  metrics aggregator + query API + alerting  │  per-UID (SO_PEERCRED),
│  (any history/DB lives HERE, never the proxy)│  already exists
└──────────────────────────────────────────────┘
            ▲  query API (UDS)
┌ attop / standalone TUI ─────────────────────┐  install · configure ·
│  one control plane, panels not tools        │  guard status/update ·
│  theme + i18n + responsive + vim/arrow keys │  live metrics · fleet
└──────────────────────────────────────────────┘
```

**The exporter only emits** — counters to atty-guard's UDS if present, else
a per-instance file under the runtime dir. No UI, no DB; hot-path cost is
atomic increments + an `onTick` flush. **atty-guard is the data hub**
(central, per-UID, persistent); fleet aggregation + alerting live there. Any
history/DB lives in the daemon or TUI — **never the proxy module**.

### `attop` is atty-session-aware [locked]

`attop` is a standalone binary, but detects when it's launched **beneath an
atty session** (`$ATTY` set) and adapts: it can run the OSC-133 / shell-
integration health-check **in-place** (the `atty doctor` logic embedded, so
the user never leaves the dashboard to debug "needs OSC 133"), and it knows
*which* instance it's inside (highlight it in Fleet). Outside atty it runs
fully standalone (reads the daemon/files only).

## The Suckless / configure tension — menuconfig, not runtime config [locked]

atty's model is *edit `config.zig`, recompile, done.* The `menuconfig`
precedent resolves it: the dashboard's "configure" is a **`config.zig`
scaffolder** — toggles regenerate the `modules` tuple + subsystem fields,
then run `zig build`. Source of truth stays `config.zig`. (`atty-guard`'s
`[profile]`/`[enforcement]` TOML — the one existing runtime config — is
edited via the existing sudo-mediated CLI, not a new path.)

## Extensibility — Suckless style (shipped)

`attop` follows the atty ethos: panels are **compile-time composed** from its
own config (`src/attop/config.def.zig` committed template →
`src/attop/config.zig` gitignored, dwm-style) — no runtime plugin loader.
`PanelHost(panels)` (`src/attop/panel_host.zig`) walks the tuple exactly like
the proxy's `Dispatcher(modules)`: every hook is `@hasDecl`-gated, so a panel
contributes zero code for hooks it omits, and deleting it from the tuple
removes it from the binary.

### Writing a panel

A panel is any type with this hook shape (`src/attop/panel.zig`):

```zig
pub const Runtime = struct { /* per-panel state, e.g. a list.List */ };
pub fn attach(allocator) !Runtime           // required
pub fn title() []const u8                    // required — tab label
pub fn navKey() u8                           // required — global hotkey
pub fn render(rt, ctx, w) !void              // required — draw content
pub fn detach(rt) void                       // optional — teardown (free attach's resources)
pub fn onKey(rt, ctx, key) !panel.Action     // optional — handled | pass | quit | refresh
pub fn onTick(rt, ctx, elapsed_ms) !void     // optional — periodic work
pub fn footerHint(rt, ctx) ?[]const u8       // optional — panel key legend
pub fn wantsFocusAtStart(ctx) bool           // optional — landing vote
```

`ctx` (`panel.Ctx`) carries the cached daemon snapshot (`metrics`,
`instances`), terminal geometry, `focused`, and a per-frame arena. `render`
writes content only — the host owns the tab bar, footer, screen clear, and the
diff render. Drop the type into the `panels` tuple and recompile:

```zig
pub const panels = .{ home.Panel, guard.Panel, fleet.Panel, my.Panel, help.Panel };
```

Reuse `list.List` for a selectable/scrollable list (Fleet + Guard do) and
`box.drawBox` for a framed detail view. Return `.handled` from `onKey` when the
panel consumed a key (so global nav doesn't also act on it), `.pass` otherwise.

## UX bar (the differentiators — this is the product) [locked]

- **Zero jargon by default.** "Kernel protection: On · blocks threats
  before they run", not "LSM `bprm_check` → EPERM". Jargon behind an
  *Advanced* toggle (progressive disclosure).
- **3-second comprehension.** The first screen *is* the answer.
- **Clean, structured, best-in-class.** Consistent palette, aligned
  columns, generous spacing, considered density.
- **Safe + reversible.** Each toggle states its consequence; dangerous ones
  (`lockdown`) gated + explained. Always an undo.
- **Alive, never flickery.** Diff-rendered (no full repaints — the proxy's
  defensive-rendering discipline), 4–10 Hz.
- **Keys: vim-style AND arrows.** `hjkl` / `gg`/`G` / `/`-search / number
  jumps, *plus* arrow keys + Tab/Enter/Esc — every action also has a
  visible label (no memorization). Mouse optional. Persistent help footer;
  `?` opens a keymap cheatsheet.
- **Responsive.** Reflows across sizes: full multi-column at ≥120 cols,
  stacked at 80×24, a compact single-column/summary mode for tiny panes;
  never breaks the layout. ASCII fallback for non-nerd-font terminals.
- **Themeable + i18n** — see below.

## Theming + i18n [locked]

- **Themes.** A theme = a named palette + glyph set (nerd-font vs ASCII)
  defined in config, dwm-style. Ship a few (dark/light/high-contrast).
  **Auto-detect by default, configurable** [locked]: detect the terminal
  background / `COLORFGBG` / `NO_COLOR` and pick a fitting theme
  automatically, with one sane default when detection is inconclusive; the
  user can pin a fixed theme in config to override. All color goes through
  the theme — no hardcoded SGR in panels (reuse
  `atty.style`/`atty.style.presets`).
- **i18n.** All user-facing strings come from a string table keyed by a
  locale (default `en`); `$LANG`/config selects it. Strings are
  length-aware (the responsive layout must tolerate translation expansion).
  The string table is the single source for the zero-jargon copy, so
  translating *is* re-skinning the plain-language voice.

## Alerting / notify channels [locked]

The daemon (where fleet events converge) can push **alerts** on notable
events (a guard block/refusal, a fleet threshold). Channels are an
**extensible, Suckless-style hook system** — not a fixed enum: a channel is
a small handler composed from config the same comptime/tuple way modules +
panels are, so users add their own (a custom script, a different chat
service) by editing config + recompiling, not via a runtime plugin API.
Shipped presets:
- **System notification** — desktop notification (`notify-send` / the
  portal) so a block surfaces even when `attop` isn't focused.
- **Webhook** — POST a JSON payload to a configured URL (Slack/Discord/
  generic), opt-in, rate-limited, redaction-aware (counts + shapes, never
  raw command content — same privacy stance as metrics).
Alert rules + channels live in atty-guard config; `attop` has an Alerts
panel to configure + test them. (Phase P6; the hook points land with the
metrics API.)

## Screens (information architecture)

| Panel | Normal user sees | Behind *Advanced* |
|---|---|---|
| **Home** | protected? what's atty doing? today's value + live feed | raw event stream, latencies |
| **Guard** | a slider `Off → Watch → Block → Lockdown`, each named + a one-line TL;DR/tip; deny-list; "update threat data" | profile internals, eBPF mode, atom corpus, verdicts |
| **AI** | active model, speed; pick a model; try a prompt | providers, endpoints, tokens/cost |
| **Modules** | toggle cards (Autosuggest, Safety rails, AI, Click-to-open…), one line each + a live "working ✓" dot | the `config.zig` it generates |
| **Fleet** | every atty terminal as a row (dir, running cmd, hit-rate, last seen); the current session highlighted | per-instance counters |
| **Alerts** | channels (system notif / webhook) + rules, with a "test" button | payload shapes, rate limits |
| **Setup** | first-run wizard + a health check ("everything's wired ✓") | the embedded `atty doctor` OSC-133 chain |

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
├ 5 terminals active ─────────── [g]uard [a]i [m]odules [?]help┤
└──────────────────────────────────────────────────────────────┘
```

### Guard slider — named rungs + TL;DR [locked]

The key normal-user moment: the security-profiles ladder as one control.
Each rung is **named in plain language with a one-line TL;DR/tip**:

| Rung (profile) | Label | TL;DR / tip |
|---|---|---|
| `prompt` | **Off-ish (Prompt)** | Only warns on the risky commands *you* type. The default tripwire. |
| `audit` | **Watch** | Watches the whole session subtree and logs threats — sees nothing you don't. Safe first step. |
| `session` | **Block (reactive)** | Watches + kills a threat right after it starts. Catches scripts that bypass the prompt. |
| `strict` | **Block (sync)** | Refuses known-bad binaries *before* they run. May occasionally stop a tool you trust — add it to the allow path. |
| `lockdown` | **Lockdown** | Freezes anything ambiguous until cleared; fail-closed. Maximum safety, can wedge — for hostile environments. |
| `smart` | **Smart** | Picks the lightest sufficient guard per command automatically. |

## First-run wizard

**Shipped.** The wizard *is* the Setup screen — there's no separate flow to
finish. attop detects what's present (it's a standalone binary, so it reads
**host + daemon** state, not atty's compiled module set) and guides the rest.

**Capability-aware landing.** On launch attop opens on **Setup** when the
stack isn't ready — atty not on `$PATH`, or the daemon unreachable on a
one-shot probe — and on **Home** otherwise. So a fresh user lands on the
checklist, not an empty dashboard.

**The Setup checklist.** One row per capability, each failing/optional one
with a one-line fix:

| Row | ✓ | otherwise |
|-----|---|-----------|
| `atty` | on `$PATH` | the `bin.atty.sh` install one-liner |
| `shell` | wired (via `$ATTY_SOURCE` or an rc integration signature) | `[w]` to wire it, or the manual `atty init <shell>` |
| `atty-guard` | daemon running | `sudo systemctl start atty-guard` |
| `security` | active profile | raise it |
| `eBPF` | attached (+ the enforcement depth) | the `GUARD_FEATURES` build |
| `features` | the daemon's compiled-in Cargo features | "minimal build" / "unknown" (older daemon) |
| `metrics` | sessions reporting | enable `metrics_exporter` |
| `session` | inside an atty session | `run: atty` |

Detection is read-only + best-effort (an unreadable rc reads as "not wired",
never an error); Home likewise shows "no metrics — enable metrics_exporter or
start a session" rather than misleading zeros when nothing is reporting.

**`[w]` — consented shell-integration write.** On a not-wired shell, `[w]`
opens a confirm view showing the **exact** lines that will be written, and
writes **only** on `y` (any other key cancels — nothing is touched without
consent). It uses a managed-snippet model:

- writes `~/.config/atty/init.<shell>` — a self-updating one-liner
  (`eval "$(atty init <shell>)"`, or `atty init fish | source` for fish) so it
  never goes stale;
- adds one **marker-guarded** block to the shell rc that exports
  `$ATTY_SOURCE` and sources that file. The block is **idempotent** (re-running
  rewrites in place, never duplicates), preserves everything outside its
  markers byte-for-byte, and the rc is **backed up** to `.atty.bak` before any
  edit (writes are atomic via temp + rename). Remove it by deleting between the
  markers. Syntax is bash/zsh/fish-aware.

`$ATTY_SOURCE` is the locator config tooling can pick up; its presence (or the
rc marker) is exactly what the `shell` row detects as "wired".

## Language & rendering [locked]

**Zig** for `attop` — reuses atty's TUI/style primitives (`ansi.zig`,
`style.zig`, the overlay/pick-list renderer), atty-branded, native for the
`config.zig` scaffolding; talks to atty-guard over the JSON-over-UDS
protocol below. For the widget/layout layer, evaluate
[`zigzag`](https://github.com/meszmate/zigzag) — **use it if it fits, else
vendor the parts we need** for an optimized, dependency-light core (Suckless
discipline: minimal deps, copy-what-you-use over a heavy framework). The
renderer must be diff-based (no flicker) + responsive-layout-aware from the
start.

## Testing — e2e, screenshot-verified [locked]

The dashboard's UX *is* the product, so it's **end-to-end tested with
screenshots**: drive `attop` in a scripted PTY (reuse the existing
`tests/e2e/` VT-grid + golden-diff harness) across sizes (120-wide, 80×24,
tiny), themes, and locales; snapshot the rendered grid and diff against
goldens. Every panel + the responsive breakpoints + the Guard slider states
get a golden. (The existing `ghost_starship_overwrite` flake is a caution:
keep snapshots deterministic — fixed clock/seed, no live timestamps in the
golden region.)

## The atty-guard metrics API (data layer) [locked]

New UDS requests alongside the existing protocol (`#[serde(tag = "method",
rename_all = "snake_case")]`), all **per-UID gated via SO_PEERCRED** (root
sees all UIDs; non-root sees only its own instances).

```jsonc
// instance → daemon (metrics_exporter, each onTick flush)
{ "method": "report_metrics", "pid": 4242, "cwd": "/home/u/proj",
  "shell": "bash", "incognito": false,
  "counters": {                       // monotonic since session start
    "commands": 312, "ghost_accepted": 188, "ghost_shown": 401,
    "keystrokes_saved": 1204, "llm_calls": 7,
    "guard_warn": 2, "guard_block": 1, "guard_refused": 1 },
  "ts_ms": 1750000000000 }
// → { "type": "ok" }

{ "method": "list_instances" }
// → { "type": "instances", "instances": [
//      { "pid": 4242, "cwd": "…", "shell": "bash", "incognito": false,
//        "last_seen_ms": …, "running": "npm install", "counters": {…} }, …] }

{ "method": "get_metrics" }
// → { "type": "metrics",
//      "aggregate": { "commands": 9123, "threats_blocked": 47, … },
//      "guard": { "profile": "session", "ebpf": "attached",
//                 "enforcement": "one_level", "atoms_version": "2026-06-20",
//                 "deny_rules": { "path": 0, "basename": 3 } },
//      "instances": <count> }
```

### Privacy / incognito [locked]

- **Default:** local-only, aggregate **counts** — never per-command
  content. No data leaves the host.
- **Incognito sessions:** report **existence** (so the fleet count + "a
  session is here" are right) **+ security events** (guard
  warn/block/refused counts — a threat matters even in incognito) — but
  **suppress the productivity counters** (commands/ghost/keystrokes/llm).
  This is the **default**, and **configurable** (a knob to report nothing,
  or to report normally, in incognito). The exporter reads `ctx.incognito`
  (the proxy already gates recording there).
- **File fallback** (no daemon): the exporter writes
  `$XDG_RUNTIME_DIR/atty/<pid>.json` (same body) + a heartbeat; the TUI
  scans + GCs stale files. Prefers the daemon API; falls back to files.

## Phasing (each step ships UX value alone)

1. **P1 — metrics plumbing.** `metrics_exporter` module (atomic counters →
   onTick flush, incognito-aware) + atty-guard `report_metrics` /
   `get_metrics` / `list_instances` (per-UID gated) + file fallback. *The
   profiles arc already produces the guard-posture half of the signal.*
2. **P2 — `attop` skeleton + the UI foundation + Home.** The render core
   (diff-based, responsive layout, theme engine, i18n string table, vim +
   arrow keymap, the e2e screenshot harness) + the Home screen. Demo-able
   MVP — and the foundation every later panel inherits.
3. **P3 — Guard panel.** The named slider + TL;DRs + deny-list + "update
   threat data" + Advanced verdicts.
4. **P4 — Fleet.** Multi-instance aggregate; current-session highlight.
5. **P5 — Modules toggle + menuconfig** (`config.zig` scaffold + `zig
   build` with progress/confirm).
6. **P6 — First-run wizard + Setup/embedded-doctor + AI panel + Alerts**
   (system notification + webhook channels, with the daemon-side hooks).

Themes/i18n/responsive/keys/e2e-screenshots are **P2 foundations** (every
panel inherits them); alerting is P6 (hooks land with P1's API).

## Resolved decisions (2026-06-27)

- Name → **`attop`** (with named rungs + TL;DRs in-panel).
- Incognito → **existence + security events by default, configurable**.
- Distribution → **separate `attop` binary**, atty-session-aware, embedded
  doctor.
- Language → **Zig**; evaluate/vendor `zigzag`.
- Keys → **vim + arrows**. Responsive → **yes**. Extensible → **Suckless,
  comptime-composed**. Themes + i18n → **yes**. Testing → **e2e screenshot
  goldens**.
- Retention → **configurable: ephemeral + persistent, one default**
  [locked]. Default = **ephemeral** (daemon memory); **persistent** (a
  small on-disk ring for history graphs) is opt-in via config. Lives in the
  daemon/TUI, never the proxy.
- Alert channels → **extensible Suckless-style hooks** [locked] (presets:
  system notification + webhook; users add their own by config+recompile).
- Theme auto-detect → **auto + configurable, one default** [locked]
  (detect terminal bg/`COLORFGBG`/`NO_COLOR`; pin a fixed theme to
  override).

## Open questions

- Persistent-retention store format (on-disk ring vs sqlite/redb) + default
  window — decide when persistence is built (post-P4).
- Webhook payload schema specifics per preset (Slack vs Discord vs generic)
  — decide at P6.

## See also

- `docs/security-profiles.md` — the Guard panel's underlying model.
- `docs/architecture.md` — the proxy + module framework the exporter joins.
- `atty-guard/src/server.rs` — the UDS protocol the metrics API extends.
