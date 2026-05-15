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

**Status**: shipped in PR #37 (commit `4edb236`).

`cfg.auto_delay_ms` is now wired: `handleDialogResponse .exec`
arms a timer when `auto_mode_active` is true (set by the
`llm_exec_auto` action). `onTick` fires `\r` once the delay
expires; any keystroke disarms via `onInput`. New e2e scenario
`llm_exec_auto_fires` pins the full step-1 → step-2 → done loop.

### Question UI (Alt+S `.question` action)

**Status**: shipped (single-question free-text) in PR #38 (commit
`8a68b82`).

Single free-form prompt: latches the LLM's question in the hint
row, transitions to `.awaiting_question_answer`, and accepts the
user's typed reply as the next `.user` turn. The `.replace_commit
= "\x15"` redirect in `onInput` keeps bash from executing the
answer as a shell command.

**Remaining**: multi-choice rendering through `ghost_list`
(Ctrl+1..9 picking). The state machine is in place; what's
missing is the rendering plumbing + a parser for `choices: []`
in the JSON envelope. Worth doing if interactive scripted flows
turn out to want pick-lists more often than free-text.

### OSC 133 edge offset (PR H)

**Status**: shipped in PR #36 (commit `84a6847`).

`edge_offsets` now stamp the leading ESC of each marker (not the
terminator). Callers slice cleanly with `bytes[cursor..offset]`;
no more backwards-walking through feed boundaries.

### Esc exits AI mode (PR I)

**Status**: shipped in PR #34 (commit `5146447`).

Both legacy `\x1b` and kitty-CSI-u `\x1b[27u` Esc bind to
`llm_exec_cancel`. The proxy clears `matched_binding` for the
unconsumed-Esc path so CSI-u cleanup translates back to legacy
when the handler declines (vim users on kitty-kbd still get bare
Esc).

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
