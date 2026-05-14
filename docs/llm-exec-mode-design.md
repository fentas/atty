# LLM exec mode — design

Design doc for the `feat/llm-exec-mode` branch. Reference while implementing; living document — anything that doesn't match the final code is wrong here, fix the doc.

## Goal

Three escalating LLM interaction modes triggered from inside an "AI mode" the user enters by typing `#: ` (with trailing space):

- **Single prompt** (`Alt+A`) — current behaviour: LLM generates one command, lands on prompt, user presses Enter to run.
- **Dialog exec** (`Alt+S`) — LLM generates a command + description, lands on prompt with a clear indicator, user confirms with Enter or cancels. Command's output is fed back to the LLM, which decides the next step (another command, a question, or "done"). Loop continues until done or cancel.
- **Auto exec** (`Alt+Shift+S`) — same loop as Dialog but commands auto-execute after a short visible delay (so the user can see and cancel them).

## Mode entry

The user types `#: ` (hash, colon, space) at the prompt. atty detects this in `line_state` and:

1. Sets `llm_exec.Runtime.ai_mode = true`.
2. statusbar swaps its base text to `AI · Alt+A single · Alt+S dialog · Alt+Shift+S auto · Alt+M model · Alt+H help · Esc cancel`.
3. User continues typing the task.

**Enter in AI mode is a no-op** (intentionally — avoids accidental LLM calls). User must explicitly press one of the action keys.

Mode exits on:

- Action key pressed (action fires, mode exits)
- `Esc` (clear line, exit mode)
- User deletes the `#: ` prefix from `line_state`

## Keybindings (defaults)

| Key | Action | Notes |
|-----|--------|-------|
| `Alt+A` | `llm_exec_single` | Single command, current `llm.zig` behaviour |
| `Alt+S` | `llm_exec_dialog` | Manual-confirm exec loop |
| `Alt+Shift+S` | `llm_exec_auto` | Auto-confirm exec loop (with brief visible delay per step) |
| `Alt+M` | `llm_exec_cycle_model` | Cycle through configured models, surface current in statusbar |
| `Alt+H` | `llm_exec_toggle_help` | Open / close help overlay |
| `Ctrl+Shift+X` | `llm_exec_cancel` | Cancel mid-execution (works during running exec loop) |
| `Esc` | (no new action) | If in AI mode: clear line + exit. Otherwise default Esc passthrough. |

`Enter` in AI mode is **swallowed** (with optional 2s statusbar hint).

## State machine

```
.idle
  ↓ (user types `#: `)
.ai_mode_entered
  ↓ (user presses Alt+A | Alt+S | Alt+Shift+S)
.generating
  ├─→ LLM error → .ai_mode_entered (error shown in statusbar, line preserved)
  └─→ LLM success
        ↓ single | dialog | auto
   ┌────┴───────────────┐
   │ single             │  dialog | auto
   ↓                    ↓
.suggesting             .suggesting (with description, indicator)
   ↓ (user Enter or cancel)
.executing              .executing
   ↓                    ↓ (OSC 133 ;C → ;D)
   exit                 .capturing_output
                         ↓ feed back to LLM
                        .generating  ← loop
                          ↓ LLM says "done"
                          exit
                        .generating
                          ↓ LLM asks question
                        .questioning (multi-choice ghost_list OR free-text prompt)
                          ↓ user answers
                        .generating  ← loop
```

Cancel (`Ctrl+Shift+X`) drops to `.idle` from anywhere.

## LLM response format (JSON)

```json
{
  "action": "exec" | "question" | "done",
  "command": "ls -la /var/log",      // when action=exec
  "description": "List recent logs", // when action=exec; shown in dialog mode
  "question": "Which log file?",     // when action=question
  "options": ["syslog", "auth.log"], // optional, multi-choice if present
  "reason": "All checks passed"      // when action=done
}
```

System prompt enforces this shape. Malformed responses trigger a retry with stricter instructions; second malformed = abort with statusbar error.

## Output capture

Uses OSC 133 `;C` (cmd start) and `;D` (cmd end). Between them, atty's master-output stream is recorded into the module's `Runtime.captured_output` buffer (capped at ~16KB; truncate with `…[truncated, M of N bytes elided]…` if exceeded).

**No OSC 133 = hard error**: when user presses Alt+S / Alt+Shift+S without `;C`/`;D` being emitted (no shell integration), abort with statusbar message: "exec mode needs OSC 133 — run `eval \"$(atty init bash)\"`". Single (Alt+A) still works without integration.

## Conversation state

`Runtime` keeps:
- `original_task: []const u8` — the user's `#: <task>` text
- `turns: []Turn` — capped at `config.history_turns_max` (default 8); older turns truncated FIFO
- `turn = struct { kind: .user | .assistant_exec | .observation | .assistant_question | .user_answer, content: []const u8 }`

System prompt assembled per-call. Token budget bound: total bytes of conversation truncated to fit `config.context_budget_bytes` (default 32KB; older turns dropped first).

## Atuin tagging

When the atuin module records a command originating from the LLM:

- `--author "llm+<model>"` — e.g. `llm+qwen3-coder`
- `--intent "<description>"` — the LLM's one-line description for this step

Implementation: the LLM module passes the metadata via a new `ctx.commit_metadata: ?CommitMetadata` field; the atuin module reads it in `onLineCommit`. If atuin v18 doesn't have `--intent`, fall back to a leading `# <description>\n` line prepended to the recorded command (atuin treats it as part of the entry; remains searchable via `atuin search llm+`).

## Guardrail v2

Refactor `src/modules/guardrail.zig` from a flat list of substrings into a typed rules array:

```zig
pub const Match = union(enum) {
    substring: []const u8,    // "rm -rf"  (cheap contains check)
    glob: []const u8,         // "sudo *"  (shell-style * ? [abc])
    regex: []const u8,        // "^rm\\s+-rf"  (small regex engine)
};

pub const AuthorMask = struct { user: bool = true, llm: bool = true };

pub const Behavior = enum {
    confirm,        // every match → y/N prompt
    confirm_once,   // first match per (rule × session) → y/N; subsequent allow silently
    block,          // refuse outright, statusbar error
    warn,           // statusbar flash, allow
};

pub const Rule = struct {
    match: Match,
    authors: AuthorMask = .{},
    behavior: Behavior = .confirm,
};
```

Default rules ship stricter behavior for `.llm` author:

| Pattern | User | LLM |
|---------|------|-----|
| `rm -rf /` (substring) | `block` | `block` |
| `^rm\s+-rf\s+/` (regex) | `block` | `block` |
| `rm -rf` (substring) | `confirm` | `block` |
| `^sudo ` (regex) | `confirm` | `confirm` |
| `mkfs` (substring) | `confirm` | `block` |
| `dd if=/dev` (substring) | `confirm` | `block` |
| `:(){:\|:&};:` (substring, fork bomb) | `block` | `block` |

Author is determined by who initiated the command:

- User-typed command → `.user`
- LLM-suggested command (via `llm_exec`) → `.llm` — carried via `ctx.commit_author: Author` field

## Help overlay (Alt+H)

Rendered using the existing `ghost_list` machinery (or a dedicated overlay if ghost_list's "pick" semantics get in the way). Shows:

```
AI Mode Help
─────────────────
Alt+A          single prompt — one command, then exit AI mode
Alt+S          dialog exec — LLM step-by-step, manual confirm
Alt+Shift+S    auto exec   — LLM step-by-step, auto-confirm
Alt+M          cycle model — current: qwen3-coder
Alt+H          toggle this help
Ctrl+Shift+X   cancel running exec loop
Ctrl+Shift+I   incognito (don't record this session)
Esc            exit AI mode (clear line)

Current task: "<task text>"
History: 0/8 turns recorded
```

Esc closes the help.

## Config (defaults.zig)

```zig
pub const LlmExec = struct {
    /// OpenAI-compatible endpoint. e.g. http://localhost:11434/v1 for Ollama.
    api_base: []const u8 = "http://localhost:11434/v1",
    /// First model in this list is the default; Alt+M cycles through.
    models: []const []const u8 = &.{ "qwen3-coder" },
    /// Maximum conversation turns kept in memory.
    history_turns_max: u8 = 8,
    /// Total bytes of conversation budget; older turns dropped to fit.
    context_budget_bytes: u32 = 32 * 1024,
    /// Auto-confirm delay in ms (so user can see the command before it runs).
    auto_delay_ms: u32 = 800,
    /// Timeout for a single LLM call.
    request_timeout_ms: u32 = 30_000,
};
pub const llm_exec: LlmExec = .{};
```

## Tests

E2E scenarios:
- `llm_exec_single_alt_a` — Alt+A flow, single command lands on prompt
- `llm_exec_dialog_happy_path` — full dialog: task → cmd → user Enter → output → LLM says done
- `llm_exec_auto_happy_path` — same flow but Alt+Shift+S, no user Enter
- `llm_exec_cancel_mid_run` — Ctrl+Shift+X during executing
- `llm_exec_guardrail_block_llm` — LLM proposes `rm -rf foo`, guardrail blocks
- `llm_exec_no_osc133` — Alt+S without shell integration → hard error
- `llm_exec_cycle_model` — Alt+M rotates statusbar text
- `llm_exec_help_toggle` — Alt+H opens/closes
- `llm_exec_question_multichoice` — LLM asks → ghost_list shows options → user picks
- `llm_exec_question_freetext` — LLM asks → user types answer → continues

Unit tests for guardrail rule matching across all three Match variants.

LLM responses in tests use a stub that reads canned JSON from a fixture file (no real network).

## Implementation order

1. **Scaffold** — design doc (this file), keymap action enum additions, default bindings.
2. **AI mode detection** — line_state-based mode flag, statusbar text swap.
3. **Guardrail v2** — refactor with all three Match variants + AuthorMask + Behavior. Backward-compat shim for existing user configs.
4. **`llm.zig` evolution** — extract LLM-call primitives, add state machine, wire actions.
5. **Output capture via OSC 133** — wire `;C`/`;D` interception into the module.
6. **Atuin tagging** — `--author` / `--intent` (or fallback).
7. **Question UI** — multi-choice via ghost_list, free-text via message area.
8. **Help overlay** — Alt+H.
9. **E2E scenarios** + golden generation.
10. **Polish + Copilot review loop**.
