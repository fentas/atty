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

- **PR #21** — feat(llm): exec dialog (Alt+S) — **merged: b1f074b** (4-round Copilot loop; user opted to stop after round 4 — 24 actionable findings addressed across rounds 1–4).
- **PR #22** — refactor(keymap): submodule folder — **merged: 79c498b**.
- **PR #23** — refactor(subprocess): submodule folder — **merged: a1823ae**.
- **PR #25** — refactor(history): submodule folder — **merged: d692dfc**.
- **PR #24** — fix(e2e): make delete_history_match_after_uparrow deterministic — **merged: e2ce456**.
- **PR #26** — feat(line-state): author propagation (Wave 1 E) — **merged: e2dfacf** (6-round Copilot loop; rounds 4–6 were docstring-style only).
- **PR #27** — feat(guardrail): author-aware Rule with AuthorMask + Behavior (Wave 2 F) — **merged: 0257dbb** (10-round loop, 13 findings).
- **PR #28** — refactor(llm): split pure parse helpers into submodule folder (Wave 2 A, slice 1 — `parse.zig`) — **merged: 9b583d3** (5-round loop, 4 findings).
- **PR #29** — feat(atuin): tag LLM-authored commits via `--author atty:llm` + LLM-side `setCommitAuthor` staging (Wave 2 G) — **merged: 5a4bf53** (7-round loop, 5 findings; round 5 caught a real shipping bug — `tag_llm_author` would've been dead code without the cross-module `setCommitAuthor` call).
- **PR #30** — refactor(proxy): split pure I/O helpers into submodule folder (Wave 2 J, slice 1 — `proxy/io.zig`) — **merged: e0a928e** (5-round loop, 3 findings).
- Remaining roadmap PRs — *queued*, listed below in shipping order.

## Shipping order — by wave

Each wave's PRs are **file-disjoint** so they can run in parallel without
rebase pain. A PR can only open once every entry in its `Depends on` column
has been merged.

### Wave 1 — opens alongside PR #21 (file-disjoint from #21 too)

| # | Branch / title | Touches | LOC | Depends on | Status |
|---|---|---|---|---|---|
| **K** | `refactor/subprocess-submodule` | `src/subprocess.zig` only | ~0 net | none | **merged: a1823ae** (PR #23) |
| **L** | `refactor/history-submodule` | `src/modules/history.zig` only | ~0 net | none | **merged: d692dfc** (PR #25) |
| **M** | `refactor/atuin-submodule` | `src/modules/atuin.zig` only | ~0 net | none | **deferred** — atuin.zig is 686 LOC, only 86 over threshold, and every inner helper closes over `cfg` so a folder split would force a leak of comptime config types through extracted helpers for marginal readability gain. Revisit if atuin grows past ~800 LOC or sprouts a logically-separable subsystem. |
| **N** | `refactor/keymap-submodule` | `src/keymap.zig` only | ~0 net | none | **merged: 79c498b** (PR #22) |
| **E** | `feat/line-state-author` | `src/line_state.zig` + `src/module.zig` | ~200 | none | **merged: e2dfacf** (PR #26) |
| **P** | `fix/delete-history-match-after-uparrow-flake` | `tests/e2e/.../scenario.e2e` + golden | ~30 | none | **merged: e2ce456** (PR #24) |

### Wave 2 — opens after PR #21 + Wave 1 prerequisites merge

| # | Branch / title | Touches | LOC | Depends on | Status |
|---|---|---|---|---|---|
| **A** | `refactor/llm-submodule` | slices 1+2: `parse.zig` + `types.zig` extracts | ~470 LOC moved | #21 | **slice 1 merged: 9b583d3** (PR #28, parse.zig). **slice 2 merged: 49b2d2c** (PR #32, types.zig — Config). Remaining slices (DialogState / Turn / Shared / HTTP worker / dialog handler all close over `cfg`) deferred — not cleanly extractable without a comptime-parameter rewrite. |
| **J** | `refactor/proxy-submodule` | slice 1: `proxy/io.zig` extract | ~50 LOC moved | E | **slice 1 merged: e0a928e** (PR #30). Render-helper slice deferred — `renderGhost` / `renderStatus` / `renderGhostList` reference internal structs scoped inside `run()` (Ghost, GhostList, AltScreen, Runtimes), so extraction needs those types lifted to module scope first. |
| **F** | `feat/guardrail-v2` | `src/modules/guardrail.zig` + e2e | ~400 | E | **merged: 0257dbb** (PR #27) |
| **G** | `feat/atuin-author-intent` | `src/modules/atuin.zig` + cross-module `setCommitAuthor` in `src/modules/llm.zig` | ~180 | E | **merged: 5a4bf53** (PR #29). M dependency dropped since M is deferred. |

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
| **O** | `refactor/guardrail-submodule` | slice 1: `guardrail/match.zig` extract | ~60 LOC moved | F | **slice 1 merged: aa1faae** (PR #31, Match union + matches + globMatch). Slice 2 (`rules.zig` for Behavior / AuthorMask / Rule / default_rules) feasible but low-value — those types are tiny and tightly coupled to `Rule`'s shape; deferred. |

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
