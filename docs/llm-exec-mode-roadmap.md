# LLM exec mode — post-#21 roadmap

Living plan for the work remaining after the Alt+S exec dialog (PR #21) lands.
Each PR below runs **10 rounds of the Copilot review loop per PR** (early-stops
on two empty rounds in a row), then squash-merges to master.

**Parallelisation:** the chain opens dependency-disjoint PRs in parallel — at
each ~5-minute wakeup tick the orchestrator processes every active PR's latest
Copilot response, then (if capacity allows) opens the next eligible queued PR.
This keeps total wall-clock close to `max(rounds_per_PR × tick_interval)`
rather than `sum(...)`. See the wave table below for the disjoint set.

PR #21 itself runs **15 rounds** rather than 10 — the user originally requested
that count at the time the loop was kicked off; subsequent PRs all use the
shorter cadence.

Cross-reference: `docs/llm-exec-mode-design.md` is the design contract; this
file is the execution log.

## Status snapshot

- **PR #21** — feat(llm): exec dialog (Alt+S) — *in review*, 15-round Copilot loop running (the one-off higher round count is intentional — see the opening paragraph).
- **PR A** onwards — *queued*, listed below in shipping order.

## Shipping order — by wave

Each wave's PRs are **file-disjoint** so they can run in parallel without
rebase pain. A PR can only open once every entry in its `Depends on` column
has been merged.

### Wave 1 — opens alongside PR #21 (file-disjoint from #21 too)

| # | Branch / title | Touches | LOC | Depends on | Status |
|---|---|---|---|---|---|
| **K** | `refactor/subprocess-submodule` | `src/subprocess.zig` only | ~0 net | none | queued |
| **L** | `refactor/history-submodule` | `src/modules/history.zig` only | ~0 net | none | queued |
| **M** | `refactor/atuin-submodule` | `src/modules/atuin.zig` only | ~0 net | none | queued |
| **N** | `refactor/keymap-submodule` | `src/keymap.zig` only | ~0 net | none | queued |
| **E** | `feat/line-state-author` | `src/line_state.zig` + `src/module.zig` | ~200 | none | queued |

### Wave 2 — opens after PR #21 + Wave 1 prerequisites merge

| # | Branch / title | Touches | LOC | Depends on | Status |
|---|---|---|---|---|---|
| **A** | `refactor/llm-submodule` | `src/modules/llm.zig` only (split into folder) | ~0 net | #21 | queued |
| **J** | `refactor/proxy-submodule` | `src/proxy.zig` only | ~0 net | E (avoids proxy.zig hook conflict) | queued |
| **F** | `feat/guardrail-v2` | `src/modules/guardrail.zig` + e2e | ~400 | E | queued |
| **G** | `feat/atuin-author-intent` | `src/modules/atuin.zig` only | ~150 | E, M | queued |

### Wave 3 — opens after A merges

| # | Branch / title | Touches | LOC | Depends on | Status |
|---|---|---|---|---|---|
| **B** | `refactor/llm-heap-promote` | `src/modules/llm/runtime.zig` (post-A) | ~80 | A | queued |
| **C** | `feat/llm-auto-exec` | `src/modules/llm/dialog.zig` (post-A) | ~150 | A | queued |
| **D** | `feat/llm-question-ui` | `src/modules/llm/dialog.zig` (post-A) + ghost_list | ~350 | A | queued |
| **H** | `feat/osc133-edge-start-offset` | `src/osc133.zig` + `src/modules/llm/dialog.zig` (post-A) | ~100 | A | queued |
| **I** | `feat/llm-esc-exits-ai` | `src/modules/llm/*` + minimal hook in proxy + keymap entry | ~80 | A, J, N | queued |

### Wave 4 — opens after F merges

| # | Branch / title | Touches | LOC | Depends on | Status |
|---|---|---|---|---|---|
| **O** | `refactor/guardrail-submodule` | `src/modules/guardrail.zig` (post-F structure) | ~0 net | F | queued |

## Per-PR protocol

1. Branch from latest `master`.
2. Implement + tests (unit, integration, e2e where applicable).
3. `zig fmt --check` + `zig build test` + `zig build itest` + `zig build e2e` (the `delete_history_match_after_uparrow` flake is pre-existing — ignore until separately fixed).
4. Conventional-commits commit. Open PR with summary + test plan.
5. **10 rounds of Copilot review loop** (`gh pr edit <N> --add-reviewer @copilot` per round, fix actionable findings, reply + resolve every thread, advance with ScheduleWakeup). Early-stop on two consecutive empty rounds.
6. After the loop closes, **squash-merge to master**, then immediately start the next PR.

## Files deliberately NOT touched

- `src/dispatch.zig` (1086) — cohesive `inline for` walker over a tuple. Splitting would force fields and helpers across files for no readability gain.
- `src/statusbar.zig` (713) — single coherent DECSTBM abstraction with tight internal coupling.
- `src/osc133.zig` (700) — single OSC-133 state machine.
- All `src/*.zig` under 600 LOC — leave alone unless a future feature grows them past the threshold.

## Termination

All Wave-1 through Wave-4 PRs (A through O) plus PR #21 merged to master. Update each row's `Status` cell to `merged: <commit>` on completion.

## Out of scope (deliberately deferred indefinitely)

- Cursor-color / cursor-shape mode indicators — design doc explicitly dropped these in favour of the statusbar segment.
- Persistent visual indicator beyond the statusbar segment — same.
- Atuin `history end` with exit codes (deferred per the design doc).
