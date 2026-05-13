---
layout: default
title: Architecture
---

# atty — Architecture

* TOC
{:toc}

## Module layout

```
src/
├── main.zig                  # CLI entry: arg parsing → proxy.run
├── root.zig                  # library entry: re-exports for `@import("atty")`
├── config.def.zig            # committed template — atty's reference config
├── config.zig                # user overrides (gitignored; seeded from .def on first build)
├── config_resolver.zig       # merges user_config with defaults via @hasDecl
├── defaults.zig              # atty-shipped default for every overridable knob
├── proxy.zig                 # poll() loop, signal handling, ghost-text scheduling
├── module.zig                # shared types: Action, Context, Error
├── dispatch.zig              # Dispatcher(modules) — comptime walker
├── keymap.zig                # Action enum + Binding struct for bindings[]
├── style.zig                 # Style struct + presets (ghost overlay, warnings, …)
├── pty.zig                   # posix_openpt / grantpt / unlockpt / fork+exec child
├── terminal.zig              # cfmakeraw-equivalent termios guard for our stdin
├── line_state.zig            # best-effort user-input buffer model
├── ansi.zig                  # SGR/CSI helpers + escape stripping
├── ghost.zig                 # ghost-text overlay state machine
├── modules/
│   ├── atuin.zig             # async Atuin module (suggest + record + sync)
│   └── guardrail.zig         # dangerous-command confirmation module
├── unit_tests.zig            # entry for `zig build test`
└── test/
    ├── integration.zig       # PTY round-trip tests (`zig build itest`)
    └── e2e/                  # scripted PTY scenarios + VT grid diff (`zig build e2e`)
```

## Comptime composition

The dispatch loop is unrolled at compile time:

```zig
inline for (config.modules, 0..) |M, i| {
    if (comptime @hasDecl(M, "onInput")) {
        switch (try M.onInput(rts[i], ctx, current)) {
            .forward => {},
            .swallow => return .swallow,
            .replace => |b| { current = b; final_action = .{ .replace = b }; },
        }
    }
}
```

Each iteration is a separate, type-checked code path. Modules that
don't declare `onInput` contribute zero bytes to this function.
Removing a module from `config.modules` eliminates *every* call path
through that module — verify with `nm zig-out/bin/atty | grep modulename`.

The `Runtimes` tuple is a heterogeneous tuple of *pointers* to each
module's runtime, built via `std.meta.Tuple`. Pointers (rather than
values) for two reasons:

1. Stable heap addresses let modules hold long-lived self-references
   (the Atuin worker thread captures `*Shared`).
2. Zig's strict "no comptime-var pointer at runtime" check
   fires when dispatch takes `&tuple[i]` on a value tuple. Pointers
   sidestep this.

`attachAll` heap-allocates one Runtime per module at startup;
`detachAll` frees them in order on shutdown.

## Data flow

```
                            ┌───────────────────────┐
       (user keyboard) ───▶ │ stdin (poll fd 0)     │
                            └───────────────────────┘
                                       │
                                       ▼
                    ┌──────────────────────────────────────┐
                    │  Keymap match (bindings[])            │
                    │  ───────────────────────              │
                    │  bytes-equal? → run Action:           │
                    │    ghost_accept → replace bytes with  │
                    │                   current suggestion  │
                    └──────────────────────────────────────┘
                                       │
                                       ▼
                            line_state.applyInput
                                       │
                                       ▼
                    ┌──────────────────────────────────────┐
                    │  Dispatcher.dispatchInput             │
                    │  ───────────────────────              │
                    │  guardrail.onInput → atuin.onInput    │
                    │  short-circuits on .swallow           │
                    └──────────────────────────────────────┘
                                       │
              ┌────────────────────────┴───────────────────────┐
              │ Action.forward / .replace                       │
              │   → write(master, …)                            │
              │ Action.swallow                                  │
              │   → do nothing (keystroke eaten)                │
              └─────────────────────────────────────────────────┘
                                       │
                                       ▼
                    ┌──────────────────────────────────────┐
                    │  if Enter committed a certain line   │
                    │  dispatchLineCommit(line)            │
                    │  (atuin records, history appends, …) │
                    └──────────────────────────────────────┘

      (shell stdout) ◀────  ┌──────────────────────────┐ ◀── read(master)
                            │ dispatchOutput            │
                            │ (observe-only; no mutation)
                            └──────────────────────────┘
                                       │
                                       ▼
                            write(stdout, output)
                                       │
                                       ▼
                            renderGhost() — gatherGhostText:
                            walks config.modules front-to-back,
                            first non-null suggestion wins
                            (or clear if every module returned null)

      (poll() timeout) ───▶ dispatchTick(elapsed_ms)
                            (TTL expiry, status indicators)
```

## Why a low-level PTY dance?

We use `posix_openpt(3)` → `grantpt(3)` → `unlockpt(3)` → `ptsname(3)`
instead of `openpty(3)` / `forkpty(3)` from `libutil`. Three reasons:

1. **Smaller link surface.** Only libc, no libutil.
2. **Explicit lifecycle.** We own the master fd from the moment it's
   allocated; the slave fd lives only inside the child between
   `setsid()`/`ioctl(TIOCSCTTY)` and `dup2()`.
3. **No BSD-isms.** `openpty` allocates a name buffer for the caller;
   we don't need that.

## Termios raw mode

We put **our** stdin into raw mode but leave the **child's** terminal
alone — the kernel sets up a fresh termios on the slave, and the
shell configures it however it wants (canonical for prompts, raw for
`vim`, etc.).

| Group | Flag           | Off because…                                          |
|-------|----------------|-------------------------------------------------------|
| iflag | IGNBRK/BRKINT  | Don't translate breaks; the shell sees raw bytes.     |
| iflag | ICRNL/INLCR    | CR ≠ LF. Conflating them breaks heredocs and editors. |
| iflag | IXON           | No XON/XOFF flow control on a local TTY.              |
| oflag | OPOST          | No \n → \r\n on our own writes; we already emit \r\n. |
| lflag | ECHO/ECHONL    | The shell echoes; doubling would show every key twice.|
| lflag | ICANON         | We want per-keystroke wakeups, not line buffering.    |
| lflag | ISIG           | Ctrl-C is a literal 0x03 to forward; not our SIGINT.  |
| cflag | CSIZE=CS8      | 8-bit clean.                                          |
| cc    | VMIN=1 VTIME=0 | read() blocks until ≥1 byte; no inter-byte timer.     |

A `defer raw.deinit()` restores the original termios on every exit
path including panics — critical, because a crashed atty must not
leave the user's terminal echoless.

## Signal handling

We use the **self-pipe trick**: signal handlers do one
async-signal-safe `write(pipe, &sig, 1)`. The main loop reads from the
pipe inside `poll()` and dispatches:

- **SIGWINCH** — query our stdout's winsize via `TIOCGWINSZ`,
  propagate to the master via `TIOCSWINSZ`. The kernel auto-delivers
  SIGWINCH to the foreground process group inside the PTY, so the
  shell and any full-screen apps (vim, less) all see the resize.
- **SIGCHLD** — `waitpid(child, …, WNOHANG)` to detect child exit and
  drop out of the loop.

Portable (signalfd is Linux-only) and obviously correct.

## Ghost-text rendering

Constraints:
- The shell owns the line; we must never leave dim bytes that the
  shell can scribble over.
- The cursor is always controlled by the shell.

Strategy: before every byte we write to stdout (whether forwarding
shell output OR the user typing), we *clear* any existing overlay
first. After every dispatch where the suggestion might have changed,
we *render-or-clear* the current best suggestion.

`Ghost.show` is idempotent: if the same text is already rendered we
emit nothing — that matters because the proxy re-renders on every
tick (default 100 ms), and naive re-paints would flicker.

| Sequence       | Meaning                                              |
|----------------|------------------------------------------------------|
| ESC 7          | DECSC — save cursor + attributes                     |
| ESC 8          | DECRC — restore cursor + attributes                  |
| CSI 2 m        | SGR dim (≈ 50% intensity in most terminals)          |
| CSI 3 m        | SGR italic (optional via `ghost.style.italic`)       |
| CSI 38;5;n m   | SGR 256-colour fg (optional via `ghost.style.fg`)    |
| CSI 0 m        | SGR reset                                            |
| CSI K          | EL — erase to end of line                            |

The exact SGR bytes emitted are driven by `config.ghost.style` — an
`atty.Style` value. `atty.Style` is the shared styling primitive used
by every visible element (ghost overlay, guardrail warning banner,
future status indicators). Fields: `bold`, `dim`, `italic`,
`underline`, `reverse`, optional 256-colour `fg`/`bg`. Named
presets are in `atty.style.presets`; module configs accept their
own style fields so a user can pull a consistent palette across
the whole proxy. Default matches fish + zsh-autosuggestions: dim only.

## Line-state model

Approximates what the user has typed, *not* what the shell currently
thinks the line is. We handle:

- Printable ASCII → append
- 0x7F / 0x08 → backspace
- 0x15 → kill line
- 0x17 → kill previous word
- 0x03 / 0x04 → clear
- 0x0D / 0x0A → submit + clear

Anything else (arrow keys, ESC sequences, tab, ctrl-R, vi mode) flips
an `uncertain` flag. While uncertain, providers suppress ghost text
until the next newline. **Stale suggestions are worse than no
suggestions** — this is the safety invariant.

Recovery: `uncertain` clears on Enter, Ctrl-C, Ctrl-D, Ctrl-G (line
reset), Ctrl-U (kill line), Ctrl-W (kill word, when it empties the
buffer), and on Backspace that brings the buffer to empty. The
principle: when the buffer is empty we can't be wrong about its
content, so we lift the gate. Arrow-key history navigation does *not*
self-recover — the user has to explicitly clear the line.

## OSC 133 prompt markers (auto-detect)

The keystroke model above is blind to anything the *shell* puts on
the prompt line — history recall (Up-arrow), tab completion, paste
expansion, `!!` substitution. For those, atty needs the shell to
tell us where its input region is. The standard wire protocol is
OSC 133:

    \x1b]133;A\x07       — prompt drawing starts
    \x1b]133;B\x07       — input region begins (user can type)
    \x1b]133;C\x07       — command execution starts (Enter pressed)
    \x1b]133;D[;<code>]\x07 — command finished

`src/osc133.zig` watches master output for these (both BEL `\x07`
and ST `ESC \\` terminators are accepted), captures the printable
bytes between `;B` and `;C` as `currentInput()`. CSI/OSC bodies are
absorbed without polluting the buffer; CR clears it (line redraw);
BS pops the last byte.

**Auto-detect.** `tracker.active` flips on only after the first
well-formed 133 marker arrives. Until then, the tracker is inert
and the proxy uses keystroke tracking only. When markers ARE
emitted, on every Enter the proxy overrides
`line_state.committed` with the tracker's captured input — so
guardrail and other modules see what the shell actually has on
the prompt, not just what atty observed in keystrokes.

**Enabling shell-side.** Markers come from shell-integration
scripts. The shortest path is `eval "$(atty init bash)"` (or
`zsh`) in your `.bashrc` / `.zshrc` — the snippet wires
PROMPT_COMMAND + PS1 (bash) or `add-zsh-hook` precmd/preexec
(zsh) to emit A/B/C/D. Ghostty's built-in integration also emits
them when `shell-integration-features` includes `osc-133`;
ble.sh, zsh4humans, VS Code's shell-integration, fig all emit by
default or via a flag. Vanilla bash/zsh without any integration
don't — atty stays on keystroke tracking, no regression.

## Config resolution

Same shape as dwm's `config.def.h` / `config.h` split, plus a tiny
resolver layer so user files only have to spell out overrides.

```
src/
├── defaults.zig          atty-shipped value for every knob
├── config.def.zig        committed template (commented examples)
├── config.zig            YOUR overrides (gitignored)
├── config_resolver.zig   merges user ↔ defaults via @hasDecl
```

### Who owns what

| File | Tracked by git? | Edited by | Purpose |
|---|---|---|---|
| `defaults.zig` | ✅ yes | atty maintainers | Actual value of every knob when the user doesn't override. New knobs land here. |
| `config.def.zig` | ✅ yes | atty maintainers | Documentation surface — `cp`-able starter with commented examples. Never read at compile time. |
| `config.zig` | ❌ **gitignored** | **you** | Your `pub const X = …` overrides. Anything you don't declare falls through. |
| `config_resolver.zig` | ✅ yes | atty maintainers | One `if (@hasDecl) user.X else defaults.X` per knob. Comptime — folded away. |

### The flow

```
                  ┌──────────────────────────┐
   first build →  │ does src/config.zig      │  no → cp config.def.zig → config.zig
                  │ exist?                   │
                  └──────────────────────────┘
                              │ yes
                              ▼
   build.zig wires:
     - user_config module ← src/config.zig
     - config module      ← src/config_resolver.zig
                              │
                              ▼
   internal code does @import("config")
                              │
                              ▼
   ┌─────────────────────────────────────────────────┐
   │ config_resolver.zig                              │
   │                                                  │
   │ pub const X = if (@hasDecl(user, "X"))           │
   │     user.X                                       │
   │ else                                             │
   │     defaults.X;                                  │
   └─────────────────────────────────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              │                               │
              ▼                               ▼
        proxy.zig                       dispatch.zig
        (reads config.keymap.bindings,  (Dispatcher(config.modules))
         config.proxy.tick_interval_ms,
         config.ghost.style, …)
```

`@hasDecl` is comptime, so the missing branch is constant-folded —
zero runtime cost compared to declaring everything explicitly.

### Day-to-day, by scenario

| Scenario | What happens |
|---|---|
| **Fresh clone**, run `zig build` | build.zig sees no `config.zig`, copies `config.def.zig` across. Build succeeds with all defaults. |
| **You edit `config.zig`** to set `ghost` | Resolver returns *your* `ghost` struct. Per-field defaults inside the struct fill any fields you didn't list. Other subsystems still come from `defaults.zig`. |
| **atty adds a new knob** | Lands in `defaults.zig` + resolver, optionally surfaced in `config.def.zig` comments. Your `config.zig` is untouched. You get the new default automatically. |
| **atty changes a default** | If you didn't override it, you get the new value. If you did, your override still wins. |
| **You `git pull`** | `config.zig` is untracked → no conflict, ever. `config.def.zig` may have new commented examples — read them at leisure. |
| **You delete `config.zig`** | Next `zig build` recreates it from the template. |
| **You want config in your dotfiles** | `make CONFIG=/path/to/mine.zig build` (or `-Dconfig=…`). Bypasses the bootstrap entirely. |

### Style rule — struct-grouped subsystems

Every subsystem is a **struct with per-field defaults**, even if it
only has one knob today. Reasons:

- New fields added upstream flow through to existing user configs via
  Zig's struct field defaults — no migration needed.
- Going flat → struct later forces every user to rewrite
  `pub const xxx_yyy = …` to `pub const xxx = .{ .yyy = … }`, which
  defeats the resolver's "no merge churn" promise.

The only flat exception is `modules`, which is a heterogeneous comptime
tuple and can't be a struct field. Type names follow `atty.Style` /
`atty.style` casing convention: `atty.Proxy` (the type) vs
`atty.proxy` (a namespace/value where one exists).

### Adding a new knob (maintainer's checklist)

**Inside an existing subsystem** (the common case):

1. Add a field to the relevant struct in `defaults.zig` with a default.
2. That's it. The resolver passes the struct through whole; existing
   user configs pick up the new field via Zig's per-field defaults.
3. Document it in `docs/providers.md` (module-specific) or here.

**New subsystem** (rare):

1. Add a new struct type + instance to `defaults.zig`.
2. Re-export the type + add the value resolver line in
   `config_resolver.zig`.
3. Add a top-level alias in `root.zig`.
4. Update `config.def.zig` + the docs.

That's the entire surface area. No user file ever has to change.

## Keymap

`src/keymap.zig` defines a closed `Action` enum and a `Binding` struct
(`{ bytes, action }`). `src/config.zig` exposes `bindings: []const
Binding` — the dwm `keys[]` equivalent. The proxy iterates the array
once per stdin read; the first byte-exact match wins.

```zig
pub const bindings: []const atty.keymap.Binding = &.{
    .{ .bytes = atty.keymap.key("Right"),  .action = .ghost_accept },
    .{ .bytes = atty.keymap.key("End"),    .action = .ghost_accept },
    .{ .bytes = atty.keymap.key("Ctrl+F"), .action = .ghost_accept },
};
```

`atty.keymap.key(name)` is a comptime-only string→bytes resolver — it
unfolds to the same `[]const u8` constant that the proxy compares
against (`"\x1b[C"` for `"Right"` and so on). Typos error at compile
time, not runtime.

Recognised names include arrows + nav (`Right`, `Home`, …),
modifier-composed forms in the xterm CSI-1 family (`Ctrl+Right`,
`Shift+End`, `Ctrl+Shift+Up`, `Ctrl+Alt+Left`), `Ctrl+<letter>`,
`Alt+<char>`, `F1`–`F12`, `Tab`, `Shift+Tab`, `Enter`, `Backspace`,
`Esc`. Things terminals can't portably encode — `Super+…` /
`Win+…` / `Cmd+…`, `Ctrl+Tab`, multi-key chords (Emacs-style
`Ctrl+X Ctrl+S`) — are not supported. For terminals that speak the
kitty keyboard protocol and emit something distinct, drop in the raw
byte literal instead.

The match must happen *before* `line_state.applyInput`, because a CSI
sequence like `\x1b[C` would otherwise flip the line into `uncertain`
state and the ghost would clear before we got a chance to consume it.

`ghost_accept` substitutes the keystroke bytes with the current
ghost-overlay text. The rest of the loop then treats them as if the
user had typed them: shell sees normal input, modules see a normal
`onInput`, line state grows by the suggestion length. Adding a new
action is one enum variant + one switch arm; no new global lists.

`incognito_toggle` (default `Ctrl+Shift+I` + `Alt+i`) flips a proxy-
local flag and forces a status-bar repaint to show the 🔒 segment.
Commits don't fire `dispatchLineCommit` while on.

`delete_history_match` (default `Ctrl+Shift+D`) fires
`dispatchDeleteHistoryMatch` on every module that implements the
hook (today: just `history`), then sends `\x15` (Ctrl+U) to the
shell so the prompt clears, and calls `StatusBar.setTransient(...)`
to flash `🗑 deleted: <line>` for 3 s before the bar reverts to its
normal text.

## Status bar + incognito

Off by default (`config.statusbar.enabled = false`); opt in if you
want a persistent indicator. When enabled:

1. **Startup**: emit DECSTBM `\x1b[1;<rows-N>r` (N = `reserve_rows`,
   default 3) to confine shell scrolling to rows 1..(rows-N). Set
   the slave PTY size accordingly via `TIOCSWINSZ` so the shell
   wraps inside the visible region.
2. **Each render cycle** (tick, keystroke, shell-output flush): the
   proxy assembles a status line — `incognito` prefix if on, then
   `config.statusbar.base_text`, then every module's `statusText`
   segment joined with ` │ ` — and paints it into row N inside a
   save-cursor / CUP-N,1 / SGR / text / sgr_reset / restore-cursor
   wrap so the shell's cursor model is untouched.
3. **SIGWINCH**: reapply DECSTBM with new bounds and resize the
   slave winsize.
4. **Exit / detach**: clear the reserved rows and reset DECSTBM.

The default `reserve_rows = 3` layout (top → bottom):

    rows - 2 :  hint / error notification
    rows - 1 :  blank padding (visual breathing room)
    rows     :  status text

The notification row is shared between two surfaces:

- **Hint** (`provideHintText` → `setHint`) — informational text in
  `hint_style` (dim italic by default). Used for LLM explanations
  of injected commands and similar annotations. 30s TTL.
- **Error** (`provideErrorText` → `setError`) — diagnostic text in
  `error_style` (muted red + leading ⚠ glyph). Takes precedence
  over hints on the same row; once the error's 60s TTL expires
  a still-active hint resurfaces. The LLM module uses this for
  "no endpoint configured", "HTTP 500", "couldn't parse response"
  — transparent failure instead of silent no-op.

Bumping `reserve_rows` to 4+ adds more blank padding above the
hint; dropping to 2 collapses hint and status onto adjacent rows
(legacy behaviour); 1 disables the hint surface entirely.

Modules participate via the optional `statusText` hook — see
[Writing a module](/modules/#statustext--contributing-to-the-status-bar) —
or via `provideHintText` / `provideErrorText`, the
[notifications-above-the-status-bar surface](/modules/#providehinttext--provideerrortext--notifications-above-the-status-bar).
The keymap action `incognito_toggle` flips a proxy-local boolean
that becomes `ctx.incognito`; the proxy then prepends a 🔒 segment
and gates `dispatchLineCommit` (no records written while on).
Bash-style **leading-space** is treated the same as incognito for a
single line — `HISTCONTROL=ignorespace` muscle memory works without
toggling.

`Ctrl+Shift+I` as the default binding for `incognito_toggle`
requires the terminal to emit a distinct sequence — classic terminal
mode collapses it to Tab. atty pushes the kitty keyboard protocol's
`disambiguate` flag (`\x1b[>1u`) at startup so Ghostty / kitty /
foot / WezTerm send `\x1b[105;6u` for Ctrl+Shift+I. Terminals that
don't support the protocol ignore the enable byte; the binding then
silently no-ops in those environments — `Alt+i` is bound as a
classic-encoding fallback. Disable the protocol push via
`config.terminal.enable_kitty_keyboard = false` if you have a reason.

**CSI-u intercept.** With the protocol on, the terminal sends CSI-u
sequences not just for our bound keys but for *any* key that gets
disambiguated (Ctrl+9, Ctrl+Shift+Right, Shift+Tab, …). The shell
doesn't speak the protocol — if those bytes reached it, you'd see
mojibake echoed back. The proxy's stdin handler runs `keymap.isCsiU`
on every read: if the input is a CSI-u sequence that didn't match a
binding, atty translates it back to its legacy byte form via
`keymap.csiUToLegacy` (so Ctrl+letter, Esc, Tab, Enter, Backspace
all still reach the shell as their classic single-byte encodings)
or drops it if there's no legacy form (Ctrl+9, etc.).

## Pick list (multi-row ghost suggestions)

The inline ghost shows the single best match after the cursor. The
**pick list** shows up to 9 alternative matches in dim rows directly
below the prompt — fish/zsh-autosuggestions don't have an equivalent,
but atuin's interactive Ctrl+R does, and the visual + UX model is
borrowed from there. Opt in with `ghost.list_count = N` (default 0 =
off). Default key bindings: `Ctrl+1..Ctrl+9` (kitty kbd) and
`Esc+1..Esc+9` (legacy ESC+digit, doubles as Alt+digit fallback) pick
the Nth entry — its trailing portion (past what the user has typed)
is substituted into the input, same as `ghost_accept` for the inline
ghost.

**Activation / deactivation** is dynamic — no permanent dead space:

1. On every input event the proxy asks `dispatchGhostList` for
   matches (first non-null wins; history walks its ring newest-first,
   atuin parses the worker's multi-line response).
2. **Want list & not active** → activate: emit `\n` × N (each LF
   scrolls the scroll region up if the prompt is near the bottom row;
   mid-screen they're just cursor moves), CUU N (cursor returns to
   the prompt row), then `\x1b[1B\x1b[1G\x1b[J` inside a save/restore
   wrap (the `\x1b[1G` step before the ED 0 is critical — without it,
   the user's typed prefix on column 1..COL_ORIG-1 of row R+1 is left
   alone and stale paint leaks through). Then `paintEntries` lays the
   list at relative descents.
3. **Want list & active & cache changed** → repaint: same descent
   loop, no LFs. Iterates `reserved_rows`, paints + EL-erases each
   slot so a shrinking list blanks its trailing rows.
4. **No matches / line cleared / line uncertain & active** →
   deactivate: same wipe sequence as the activate "make-room" tail
   (`\x1b[1B\x1b[1G\x1b[J`) inside save/restore. The cursor does NOT
   scroll back — the prompt stays at the screen position activate
   floated it to, matching atuin Ctrl+R's UX.

**Why dynamic, not DECSTBM-reserved.** An earlier attempt inflated
`statusbar.reserve_rows` by `list_count` so DECSTBM permanently
constrained the shell. It worked but felt "constantly spaced" at the
bottom even when nothing was shown. The LF + CUU dance gives the
same room-making behavior on demand, releases the rows when the
list goes empty, and doesn't require DECSTBM coordination with the
statusbar's existing reservation.

**Known limitation.** When the shell scrolls output past the prompt
(Enter + multi-line command output), the painted list rows scroll up
with the rest of the content. They reappear on the next user
keystroke — at the new prompt's row. There's no DECSTBM constraining
shell scrolling away from the list rows in this mode.

## Concurrency

The proxy is single-threaded except that each module may own a
background worker thread.

The Atuin module's worker handles three jobs through one mailbox:

```
main thread          shared (mutex)              worker thread
───────────          ──────────────              ─────────────
onInput      ─────▶  req_buf  ───────────────▶  read latest
                     req_gen ↑                   run lookup
                                                 res_buf  ◀──── write result
                     res_gen ↑
provideGhostText ◀── read res_buf

onLineCommit ─────▶  rec_buf  ───────────────▶  read pending
                     rec_pending ↑               atuin history start
                                                 (then maybe atuin sync
                                                  on a detached thread)
```

Coalescing falls out naturally: each new keystroke overwrites the
pending request, so the worker only ever sees the most recent state.
No queue, no backpressure.

`atuin sync` runs on a *detached* `std.Thread.spawn` so the worker
never blocks on network round-trips — without that, every record
would stall the next ~5–30 seconds of queries and the ghost would
appear stuck.

## Future work

- **OSC 133** prompt-marker awareness — the shell can emit `OSC 133 ; A`
  before each prompt; using that, we could throw away half of our
  line-state guesswork.
- **Atuin daemon socket** — once Atuin's IPC stabilises, swap the
  subprocess backend for a long-lived Unix socket.
- **Bracketed-paste detection** — suppress ghost text during a paste
  burst.
- **PTY ring buffer** — needed only if a future module wants to
  parse fragmented ANSI sequences in `onOutput` (e.g. an OSC 133
  parser); core path doesn't need it.
