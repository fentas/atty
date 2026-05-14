# LLM exec mode — post-#21 roadmap

Living plan for the work remaining after the Alt+S exec dialog (PR #21) lands.
Each PR below ships in order, runs **10 rounds of the Copilot review loop**
(early-stops on two empty rounds in a row), then squash-merges to master before
the next one begins.

Cross-reference: `docs/llm-exec-mode-design.md` is the design contract; this
file is the execution log.

## Status snapshot

- **PR #21** — feat(llm): exec dialog (Alt+S) — *in review*, 15-round Copilot loop running.
- **PR A** onwards — *queued*, listed below in shipping order.

## Shipping order

| # | Branch / title | Scope | LOC | Depends on | Status |
|---|---|---|---|---|---|
| **A** | `refactor/llm-submodule` — `refactor(llm): split into submodule folder` | `src/modules/llm.zig` (3.5 k LOC) → `llm.zig` + `llm/{dialog,worker,single,parse}.zig` via sibling `@import` | ~0 net | #21 merged | queued |
| **B** | `refactor/llm-heap-promote` — `refactor(llm): heap-allocate captured_output + last_assistant_json` | Move the two big inline Runtime buffers (16 KB + 4 KB) onto allocator-owned slices; free in `detach`. Closes Copilot round-1 follow-up. | ~80 | A | queued |
| **H** | `feat/osc133-edge-start-offset` — `feat(osc133): track ESC offset for each edge` | Add `edge_start_offsets[]` alongside `edge_offsets[]`; lets `llm.zig`'s onOutput slice marker bodies cleanly even across feed boundaries (removes the multi-feed caveat documented in PR #21). | ~100 | none | queued |
| **I** | `feat/llm-esc-exits-ai` — `feat(llm): Esc exits AI mode` | Route Esc through module dispatch; binds to a new `llm_exec_cancel`-equivalent that wipes line + exits AI mode. Currently Esc flows to readline. | ~80 | A | queued |
| **C** | `feat/llm-auto-exec` — `feat(llm): Alt+Shift+S auto exec` | Skip the .suggesting → user-Enter gate; use `auto_delay_ms` for a visible-cancel window. Small delta on top of the dialog state machine. | ~150 | A | queued |
| **D** | `feat/llm-question-ui` — `feat(llm): question UI (action="question")` | Multi-choice via existing `ghost_list` overlay; free-text via inline prompt. JSON parse already lands `question` + `options` in PR #21, just unwired. | ~350 | A | queued |
| **E** | `feat/line-state-author` — `feat(line_state): author propagation` | Add `Author` enum to commit metadata; thread `.user` vs `.llm` through proxy → line_state → onLineCommit; new `ctx.commit_author` field. | ~200 | A | queued |
| **F** | `feat/guardrail-v2` — `feat(guardrail): v2 — Match union + AuthorMask + Behavior` | Refactor flat substring list into typed rules: `substring`/`glob`/`regex` × `AuthorMask` × `Behavior` (`confirm`/`confirm_once`/`block`/`warn`). Ship the defaults from `docs/llm-exec-mode-design.md`'s rule table. Pre-1.0 — break old user configs without a shim. | ~400 | E | queued |
| **G** | `feat/atuin-author-intent` — `feat(atuin): --author / --intent tagging` | Pass LLM step's description as intent metadata. Fall back to leading `# <desc>\n` prefix when atuin lacks `--intent` (v18). | ~150 | E | queued |

## Per-PR protocol

1. Branch from latest `master`.
2. Implement + tests (unit, integration, e2e where applicable).
3. `zig fmt --check` + `zig build test` + `zig build itest` + `zig build e2e` (the `delete_history_match_after_uparrow` flake is pre-existing — ignore until separately fixed).
4. Conventional-commits commit. Open PR with summary + test plan.
5. **10 rounds of Copilot review loop** (`gh pr edit <N> --add-reviewer @copilot` per round, fix actionable findings, reply + resolve every thread, advance with ScheduleWakeup). Early-stop on two consecutive empty rounds.
6. After the loop closes, **squash-merge to master**, then immediately start the next PR.

## Termination

All nine PRs (A through G) merged. At that point the LLM exec stack is feature-complete per `docs/llm-exec-mode-design.md`. Update this file's status table as we go; mark the row `merged: <commit>` on completion.

## Out of scope (deliberately deferred indefinitely)

- Cursor-color / cursor-shape mode indicators — design doc explicitly dropped these in favour of the statusbar segment.
- Persistent visual indicator beyond the statusbar segment — same.
- Atuin `history end` with exit codes (deferred per the design doc).
