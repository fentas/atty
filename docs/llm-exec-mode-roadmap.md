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

## Phase 2 — refactor sweep (after A–G are all merged)

Apply the same submodule-folder pattern (`src/modules/llm.zig` style) to the other big files in the tree. Same per-PR protocol: 10 rounds Copilot, squash-merge between. Each is a pure structural change — no behavior delta.

| # | Branch / title | Target file | LOC | Notes |
|---|---|---|---|---|
| **J** | `refactor/proxy-submodule` — `refactor(proxy): split into submodule folder` | `src/proxy.zig` (1515) | ~0 net | Natural seams: signals (`SIGWINCH`, `SIGTERM`), ghost overlay coordination, statusbar reapply, stdin → dispatch path. Heaviest split in the sweep — likely 5 sibling files. |
| **K** | `refactor/subprocess-submodule` — `refactor(subprocess): split into submodule folder` | `src/subprocess.zig` (1247) | ~0 net | Inspect internals first — likely splits along tracker / push-pop / recognised-launcher classification. |
| **L** | `refactor/history-submodule` — `refactor(history): split into submodule folder` | `src/modules/history.zig` (852) | ~0 net | Splits: ring buffer, `~/.bash_history` I/O, `provideGhostText` + pick list. |
| **M** | `refactor/atuin-submodule` — `refactor(atuin): split into submodule folder` | `src/modules/atuin.zig` (686) | ~0 net | Splits: async worker, atuin CLI invocations, ghost + pick list. PR G's `--author`/`--intent` work lands inside this structure already split. |
| **N** | `refactor/keymap-submodule` — `refactor(keymap): split into submodule folder` | `src/keymap.zig` (792) | ~0 net | Splits: Action + Binding types, `key("Ctrl+Shift+I")` parser, kitty CSI-u encode/decode. |
| **O** | `refactor/guardrail-submodule` — `refactor(guardrail): split into submodule folder` | `src/modules/guardrail.zig` (604 pre-F → ~1k post-F) | ~0 net | **Lands AFTER PR F's v2 refactor** — F triples the size; splitting beforehand would just be re-split work. |

### Files deliberately NOT in phase 2

- `src/dispatch.zig` (1086) — cohesive `inline for` walker over a tuple. Splitting would force fields and helpers across files for no readability gain.
- `src/statusbar.zig` (713) — single coherent DECSTBM abstraction with tight internal coupling.
- `src/osc133.zig` (700) — single OSC-133 state machine.
- All `src/*.zig` under 600 LOC — leave alone unless a future feature grows them past the threshold.

## Termination

All of Phase 1 (A through G) + Phase 2 (J through O) merged. Update this file's status table as we go; mark each row `merged: <commit>` on completion.

## Out of scope (deliberately deferred indefinitely)

- Cursor-color / cursor-shape mode indicators — design doc explicitly dropped these in favour of the statusbar segment.
- Persistent visual indicator beyond the statusbar segment — same.
- Atuin `history end` with exit codes (deferred per the design doc).
