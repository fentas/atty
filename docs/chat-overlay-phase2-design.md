# chat-overlay phase 2 — design doc

Status: **brainstorm**, to be revised together.

Phase 1 (PR #48, shipped) made the LLM-session "conclusion banner" re-emittable via `Alt+C` (`llm_chat_overlay_toggle`). Phase 2 turns that action into a persistent, interactive overlay that hosts a back-and-forth conversation with the LLM, openable at any time — including during long-running subprocesses.

## Goals

| # | Goal | Why |
|---|------|-----|
| 1 | Persistent overlay window | conversation state survives across shell prompts |
| 2 | Chat input INSIDE the overlay | typing into a "comment box" instead of the shell prompt — no risk of accidentally running a command |
| 3 | LLM round-trip from the overlay | type → submit → wait → response, all without leaving overlay |
| 4 | Always-openable | open while `find /` is still running; ask "what does this output mean?" mid-stream |
| 5 | Auto-open on language answers | when the LLM produces a long-form prose answer (no `action=exec` / `question`), open the overlay automatically so the user can react |
| 6 | Re-show after close | the next Alt+C re-shows the latest conversation, not a blank slate |
| 7 | Doesn't break long-running subprocess output | the overlay's bytes can't leak into the running command's output stream |
| 8 | Doesn't break the user's shell prompt | overlay close restores the prompt at its actual position with no scroll-region damage |

## Non-goals

- Multi-tab / multi-session conversations (single conversation per atty session).
- Markdown rendering inside the overlay (text + ANSI passthrough only).
- File-attachment / image-paste (text-only chat).
- Search-history inside the overlay (Alt+C re-shows latest; no scrollback search).

## Surface

```
┌─ shell screen ──────────────────────────────────────────────┐
│                                                             │
│ $ diff -r /mnt/a /mnt/b                                     │
│ Only in /mnt/b/foo: bar.txt                                 │
│ Only in /mnt/b/foo: baz.txt                                 │
│ Files /mnt/a/x.txt and /mnt/b/x.txt differ                  │
│ ┌─ atty chat ────────────────────────────────────────────┐  │
│ │ You: explain what `Files X and Y differ` means here    │  │
│ │ ✨ atty: Two files with the same name but different    │  │
│ │   contents. Their byte-level checksums don't match.    │  │
│ │   To see the actual diff, pass `--brief` for the       │  │
│ │   summary or omit it for the full diff.                │  │
│ │ ──────────────────────────────────────────────────────  │  │
│ │ > _                                                    │  │
│ └────────────────────────────────────────────────────────┘  │
│ Only in /mnt/a/qux: file2.txt                               │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

The overlay floats above the shell scrollback (alt-screen) so it doesn't disturb output. When closed, the alt screen exits and the user sees the shell's continuing output without any artifacts.

## Triggers — when does the overlay open?

1. **Manual:** `Alt+C` (existing keybinding). Re-binds from "re-emit conclusion banner" (phase 1) to "open/close chat overlay". The conclusion banner becomes the *content* of the overlay when one exists; otherwise the overlay opens to an empty chat.
2. **Auto on language answer:** when the LLM responds with prose-only (no `action=exec`, no `question`, no `command` field), and the overlay isn't already open, auto-open it so the user sees the response without having to press Alt+C. Detected at the same point `handleDialogResponse` parses the reply — see "Auto-open detection" below.
3. **Auto on `action=done` with non-empty `reason`:** phase 1 emits the conclusion banner inline; phase 2 lifts that into the overlay so the conclusion is visible alongside any follow-up the user wants to ask.

User can suppress auto-open via `config.chat_overlay.auto_open = false`.

## Auto-open detection

The LLM's reply is parsed in `handleDialogResponse` (currently in `llm.zig`, would benefit from extraction in a follow-up). The parser returns a `Response` with `action ∈ {.exec, .question, .done}` plus prose fields (`description`, `reason`).

A reply is a "language answer" when:
- `action == .done` AND `reason.len > 0`, OR
- The reply doesn't fit any of the structured actions and falls into the "raw prose" path (currently triggers a parse-retry — phase 2 should distinguish "prose by design" from "malformed JSON" via a heuristic: presence of conversational tokens like "you can…", "to do X…", "the …", etc.).

Simpler rule for v1: only auto-open on `action=done` with a non-empty `reason`. The "raw prose" case stays as a parse-retry until the model is asked nicely.

## State machine (per session)

```
                   ┌──────────┐
                   │  closed  │  ← initial state
                   └──────────┘
                        │
              Alt+C OR auto-trigger
                        │
                        ▼
        ┌────────────────────────────┐
        │ open (alt-screen + overlay │
        │  rendered, chat input has  │
        │  focus, shell suspended)   │
        └────────────────────────────┘
            │           │              │
         Alt+C       Esc          Enter on input
            │           │              │
            ▼           ▼              ▼
        closed       closed       ┌──────────────────┐
                                  │ submit user turn │
                                  │ → worker thread  │
                                  └──────────────────┘
                                          │
                                          ▼
                                  ┌──────────────────┐
                                  │ awaiting reply   │
                                  │ (overlay shows   │
                                  │  "thinking…")    │
                                  └──────────────────┘
                                          │
                                          ▼
                                  ┌──────────────────┐
                                  │ render reply     │
                                  │ → back to open   │
                                  └──────────────────┘
```

## Implementation pieces

### 1. Alt-screen overlay primitive (new)

A new module-level helper, probably `src/chat_overlay.zig`, owns:
- The DECSET 1049 enter/exit (`\x1b[?1049h` / `\x1b[?1049l`).
- Drawing the chrome (border + title).
- Reading from the LLM module's turn history for content.
- A small input-row state machine (cursor, simple editing — left/right arrows, backspace, no kill-line yet).

The proxy doesn't currently have a "modal overlay that captures input" concept — every keystroke today goes to either the shell or a keybinding action. Phase 2 adds a third routing target: when overlay is open, stdin goes to the overlay's input handler instead of the shell.

### 2. Always-openable: stdin re-routing while overlay is open

When the overlay is open:
- Stdin bytes are intercepted at the dispatch site (`D.dispatchInput`) before they reach the shell.
- The LLM module's `onInput` consumes them as overlay input (typing into the chat box).
- Special keys (Alt+C close, Esc close, Enter submit, arrows for edit) handled in the overlay's input state machine.
- The shell continues running in the background — any output it produces accumulates in the master read path but doesn't write to stdout while alt-screen is active.

Long-running subprocesses (the `diff -r` case) keep going on the shell side; their output buffers in the kernel PTY buffer until the user closes the overlay and bytes flush.

**Edge case:** PTY buffer fills if the subprocess is very chatty (e.g. `find / 2>&1`). At ~64KB the writer blocks. atty can either:
- (a) Drain into a ring buffer and replay on overlay-close.
- (b) Let the writer block — the subprocess pauses while the overlay is open.

(b) is simpler and matches user intent ("focus on the chat, then come back").

### 3. Overlay content from the conversation

Phase 1 stores a `conclusion_buf` for `action=done` replies. Phase 2 generalises: the overlay renders the entire `Runtime.turns[]` ring (already exists), turn-by-turn:
- `.user` turns: "You: <content>"
- `.assistant_exec` turns: "✨ atty: " + the parsed `reason` / `description` (not the raw JSON envelope)
- `.observation` turns: collapsed by default ("⤓ <bytes> from `<cmd>`"), expandable on click (not in v1)

For v1, render only the most recent N turns that fit in the overlay's row budget; provide a Pg-Up / arrow scroll keybinding for older.

### 4. Chat input handling

A dedicated input row at the bottom of the overlay:
- Visible prompt: `> `
- A small fixed buffer (e.g. 4 KB) for the user's typed message.
- On Enter: push as `.user` turn, fire a worker request (reuse the dialog worker path), set state to "awaiting reply".

The user can paste multiline content — we treat embedded newlines as `\n` in the message body, not as send.

### 5. LLM round-trip

The existing `worker_mod` already handles request/response with the `Shared` mailbox. The chat overlay's submit path differs from `Alt+S` dialog mode only in:
- The system prompt may be different ("you're a helpful assistant", not the exec-loop's JSON-envelope rules).
- The reply is rendered as prose, not executed as a command.

We can add a new dialog state — `.chat_open` — that the response handler keys on to decide "render in overlay" vs "render at prompt".

### 6. Auto-open trigger plumbing

`handleDialogResponse` already knows when it's done parsing a reply. After the existing `action == .done` arm (which captures the conclusion banner), add:

```zig
if (action == .done and reason.len > 0 and !overlay.is_open) {
    overlay.open(rt, ctx); // sets the alt-screen, paints, focuses input
}
```

This needs `overlay` to be a `Runtime`-owned struct, not a global — atty supports multiple modules but only one LLM module per session, so one overlay state per Runtime is fine.

## Open questions

1. **Keybinding for `Alt+C` close vs. open** — does the same key toggle, or is there a separate close (Esc) too? Probably both: Alt+C toggles, Esc closes.
2. **Where does the user's typed-but-not-submitted draft go on overlay close?** Lost (v1), or auto-saved as a draft (v2)?
3. **Scroll inside the overlay** — Pg-Up / Pg-Down? Arrow keys? Mouse wheel (kitty mouse protocol)?
4. **Long replies that overflow the overlay** — scroll or auto-truncate with "show more"? v1: scroll.
5. **What happens if the user runs Alt+C while a `;C`-bracketed subprocess is mid-output?** The overlay opens (alt-screen enters); the subprocess continues but its output buffers. On overlay close, the buffered output replays. Need to verify the OSC 133 tracker doesn't lose its phase across alt-screen enter/exit.
6. **Worker thread cancellation** — if the user closes the overlay while a request is in flight, should we cancel? Probably yes (free the worker for the next request).
7. **Status-bar segment** — does the bar still show "AI mode" hint when the overlay is open? Or hide everything except a single "chat open" indicator? v1: hide, since the overlay itself is the indicator.
8. **Re-show after close** — Alt+C re-opens to the same content (most recent turn at the bottom). Confirmed by goal 6.
9. **Pasting** — multi-line paste arrives as one chunk; should we render the paste preview before submission? v1: just paste it into the input buffer.
10. **First-time UX** — when overlay opens to an empty session (no prior turns), what does the user see? Probably a hint: `Type a message and press Enter. Alt+C or Esc to close.`

## Phasing within phase 2

Phase 2 is large — break into commits / sub-PRs:

| Sub-PR | Scope |
|--------|-------|
| 2a | Alt-screen overlay primitive + Alt+C toggle (open/close only, no input yet, renders existing turns) |
| 2b | Chat input row (typing, basic editing, Enter to send) — round-trips through existing worker |
| 2c | Auto-open on `action=done` with non-empty reason |
| 2d | Stdin re-routing while overlay open (decouples from shell), scrolling, paste |
| 2e | Polish: status-bar interaction, draft preservation, first-time UX hint |

Each sub-PR is reviewable independently. 2a establishes the rendering surface; 2b-d build on it.

## Risks

- **Alt-screen + OSC 133 interaction**: atty's tracker uses alt-screen-active to suppress some bookkeeping. Need to verify overlay's alt-screen doesn't confuse the `;A`/`;B`/`;C`/`;D` state machine for the shell that's still running underneath.
- **Long-running subprocess PTY buffer fill**: as noted above, the writer blocks at ~64KB. Document; don't fix in v1.
- **Window resize while overlay open**: atty re-applies DECSTBM on SIGWINCH; the overlay needs its own resize handler that re-paints chrome at the new size.
- **Reentrancy**: another module's hook (atuin, history) shouldn't be able to scribble onto the overlay's screen real estate. Module dispatch happens before the overlay renders, so we need to either suspend other modules' output paths while overlay is open, or treat overlay-open as a special render mode that wins all output races.

## Open input from user

User input from earlier conversation:
- "be able to open it any time - e.g. for these long running process to ask questions during these" → goal #4
- "llm should be able to open it if it will answer a language question (e.g. explain to me ..)" → goal #5

## Next step

Walk through this doc together. Decide:
1. Sub-PR phasing — proceed in 2a→2e order, or different?
2. Auto-open trigger: just `action=done`+reason, or also the "raw prose" case?
3. Stdin re-routing: implement in 2a (simpler scope, no actual input handling yet) or defer to 2d?
4. Open-question answers (#1-10 above) — agree on each before code.

Once aligned, sub-PR 2a is ~300-400 LOC: alt-screen toggle + chrome + render existing turns. No new state machine yet.
