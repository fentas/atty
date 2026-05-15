---
layout: default
title: Follow-up improvements
---

# Follow-up improvements — design questions to revisit

Tracking items that surfaced during the Wave 2/3/4 refactor sweep
+ feature implementation but are deliberately deferred because they
either:

- need design input I don't want to make unilaterally,
- are mechanical-but-low-value and would just churn the diff
  without changing behavior, or
- are blocked by an architectural decision that the current pre-1.0
  code shape can't cheaply support.

Order = roughly "smallest-question first."

## Refactor sweep — deferred extracts

### A slices 3+ — llm.zig dialog / worker / Shared

**Status**: deferred.

`DialogState`, `Turn`, `DialogResponse`, `Shared`, and the HTTP
worker thread all close over `cfg` (a comptime parameter of
`configure()`). To extract them into sibling files we'd need each
helper to take `comptime cfg: Config` (or relevant subfields) as a
parameter — same pattern as `buildRecordArgv` in `atuin.zig`. The
mechanical work is straightforward but the comptime parameter
plumbing through dialog state transitions + worker mailbox makes
the diff large and error-prone in one PR.

**Question**: is the readability win worth it, or should we just
let llm.zig stay ~3 KLOC until a feature PR motivates the split?

### J slice 2 — proxy/render.zig

**Status**: deferred.

`renderGhost`, `renderStatus`, `clearGhost`, `renderGhostList`,
`deactivateGhostList` reference `Ghost`, `GhostList`, `AltScreen`,
and `D.Runtimes` — all of which are scoped inside `proxy.run()`'s
local frame. To extract these we'd first lift those types to
module scope. Doable but invasive (touches every line in `run()`
that constructs or mutates one of those structs).

**Question**: same as A — is module-scope hoisting the right
shape, or should run() stay as the canonical owner of these
short-lived loop-local types?

### PR M — atuin submodule split

**Status**: deferred (`docs/llm-exec-mode-roadmap.md` already
notes this).

atuin.zig is 686 LOC, just 86 over the original 600-LOC threshold,
and every inner helper closes over `cfg`. Revisit if atuin grows
past ~800 LOC or sprouts a logically separable subsystem.

## Feature gaps in shipped code

### Atuin `--intent` (the other half of PR G's design)

**Status**: not implemented.

PR #29 (G) shipped `--author atty:llm` but deferred the `--intent
"<description>"` half. The LLM module's `last_assistant_json`
contains the dialog response's `description` field; threading it
to `atuin.onLineCommit` is the missing wire. Two approaches:

1. Add `ctx.intent: ?[]const u8` alongside `ctx.line.committedAuthor()`
   — generic enough for any future "tag the commit with extra
   metadata" use case.
2. Stash the description on `LineState` next to `committed_author`,
   accessed via a new `LineState.committedIntent()` method —
   mirrors the author pattern but adds a field that's `null` for
   user-typed lines.

**Question**: approach 1 (ctx-level) or 2 (line-state-level)?
Approach 2 matches the existing author pattern; approach 1 keeps
LineState focused on text + author.

### Auto-exec (Alt+Shift+S)

**Status**: stub.

The action handler at `llm.zig` (search for `llm_exec_auto`) prints
`"auto exec coming in a follow-up PR — use Alt+S for now"` and
returns. PR C in the roadmap would wire this. `cfg.auto_delay_ms`
is already defined (800ms default) — the work is:

1. After the LLM injects a command on the dialog `.exec` path,
   start a tick-based timer.
2. On expiry, send `\r` to the PTY automatically.
3. Any user keystroke during the window cancels the auto-fire.

**Question**: anything design-y to lock down before I implement?

### Question UI (Alt+S `.question` action)

**Status**: not implemented.

PR D in the roadmap. The LLM's JSON envelope can return
`{"action": "question", "prompt": "…", "choices": ["a", "b"]}`.
Today, dialog mode handles `.exec` and `.done` but not
`.question`. The design doc says use `ghost_list` to render the
choices below the prompt (Ctrl+1..9 to pick); free-text answers
land in a status-bar input ribbon.

**Question**: design doc covers the rendering. The trickier piece
is the *threading*: where does the answer go in the conversation
history? As a `user` turn in the next request? Or a new `TurnKind`
(say, `.user_answer`)?

### OSC 133 edge offset (PR H)

**Status**: not implemented.

PR H in the roadmap. The current edge-detection in OSC 133's
parser sometimes misses the cmd_start boundary by one byte on
specific shell-integration flavours. The design doc has a one-line
fix: walk back to the ESC instead of stopping at BEL.

**Question**: low-risk, just needs testing across the
shell-integration matrix (Ghostty's snippet, ble.sh, zsh4humans,
VS Code's). I can ship this without design input.

### Esc exits AI mode (PR I)

**Status**: not implemented.

PR I in the roadmap. Pressing Esc while in AI mode should exit
back to the local prompt + clear any pending injection. Today Esc
falls through to the shell. The design doc specifies the
keybinding (`Esc` → `llm_exec_cancel`).

**Question**: scope question: does "exit AI mode" mean abort the
current step (single-step) or unwind the whole conversation
(clear history too)? Design doc says "exit AI mode (clear line)"
— I'll interpret that as abort-current-step, preserve history.

## Architectural questions

### Should `ctx.line.committedAuthor()` move to `ctx.committed_author`?

PR #26 put the author on `LineState`. Reasonable — author is
intrinsic to the committed line. But the pattern of "every
metadata field hangs off LineState" doesn't scale; a future
"committed by which model?" or "committed under which subprocess
frame?" would balloon LineState.

**Alternative**: a `Context.metadata: CommitMeta = .{}` field that
holds author, intent, model name, subprocess snapshot, etc.

**Question**: is this premature factoring, or is it the right
shape to settle before LineState grows more fields?

### Test discovery — `_ = @import("sibling.zig")` cascade

PR #30 review caught that `proxy.zig` is NOT imported by
`unit_tests.zig` (because proxy depends on user config.zig). The
workaround was importing `proxy/io.zig` directly from
unit_tests.zig. Now every submodule sibling needs explicit
registration in unit_tests.zig instead of cascading through a
`test { _ = sibling; }` block in the parent.

**Question**: is the explicit registration the right shape, or
should we factor the config-dependent code out of proxy.zig so the
unit-test root can import it cascadingly?

## Known low-value items (not blockers)

- **`MEMORY.md` / claude memory entries** — none touched this
  session; no new user preferences or feedback to record beyond
  what's in `CLAUDE.md` already.
- **`docs/architecture.md`** — could grow a "module submodule
  folder pattern" section now that 5 modules use it. Drive-by
  cleanup; not blocking anything.
- **Goldens recorded with `atty_version = 0.1.0`** — many e2e
  goldens still hold the old version stamp because we deliberately
  reverted env.toml regen during PR #27. Either accept the drift
  (informational only; harness doesn't compare versions) or do a
  one-shot regen pass.
