# Chat panel UI/UX proposals

> **Status (2026-06): proposals, not committed work.** The base chat surfaces (`Alt+C` inline panel, `Alt+Shift+C` overlay) have since shipped; the redesigns below are unbuilt ideas kept for reference.

Status: research / proposals only. Pick one (or stitch pieces from a few)
before designing. Each proposal lists the user-visible change, the
implementation surface, and the tradeoffs honestly. None of these is
implemented yet.

## Where we are today (as of June 2026)

- Two surfaces: inline panel (`Alt+C`, ~10 reserved rows above the
  statusbar) and full-screen overlay (`Alt+Shift+C`).
- Inline panel chrome: dim divider (icon + `atty chat` + provider
  name), scrollback rows that flow newest-on-bottom, single input
  row with `❯ ` prompt + reverse-video cursor.
- Turn rendering: assistant `.exec` renders structured (description
  + `$ command` block); `.done` renders `✓` + reason; `.question`
  italic prompt + numbered choices; user turns appear inline.
- Recent additions: `chat_retry_pending` banner (`↻ Enter retry · Esc
  dismiss`), Up/Down multi-line nav, Ctrl+C clears, Ctrl+Alt+Up/Down
  resize. `Alt+T` toggles auto-exec, `Alt+M` cycles model, `Alt+R`
  recalls last persisted dialog.
- One-off latches: `chat_refocus_pending` (defocus on `.exec`,
  refocus on `;D`), question pick-list (free-text row + numbered
  rows), `chat_open_cursor_row/col` snapshot, fast-path replay of
  the input block.

The current look is **functional but visually noisy** — three to five
distinct accent colors per row, mixed bold/dim treatments, and chrome
that competes with the shell prompt for eye attention. The proposals
below all aim at "clean, simple, clear, structured, neat" per the
user ask.

---

## Proposal A — Minimal mode (recommended starting point)

**Premise:** the panel is a focused conversation, not a dashboard. Drop
every chrome element that the user can derive at a glance.

### What the user sees

```
─── chat · opus ──────────────────────────────── ⌥C close ─

  You    rebuild the failing test fixture for the parser
  atty   I'll regenerate it from the seed JSON.
  $ python scripts/gen_fixture.py --seed parser.json
  ───
  You    perfect, push
  atty   pushing now
  $ git push

  ❯ |
```

- Single-line divider at the top with `· opus` to disclose the
  provider model and a right-aligned `⌥C close` reminder.
- No bottom divider — let the input row sit directly under
  scrollback, separated only by a blank line.
- Author labels (`You` / `atty`) in dim text. No avatar glyph, no
  per-row ❯ prompt mark.
- Exec commands collapse to a single line `$ <cmd>` (no description
  unless explicitly long). When output captures, render an unobtrusive
  `└─ 12 lines · ⌥⇧C to inspect`.
- Status info (auto/dialog mode toggle hint, `⌥M cycle model`) moves
  OUT of the panel and INTO the statusbar segment.
- Cursor is a single block character (no `❯ ` prefix on the input
  row); the empty line above the cursor visually disambiguates input
  from scrollback.

### Implementation

- Strip the per-row prompt glyph painting in `paintInputBlock` —
  replace with a single block-cursor render at row 0.
- Move the right-aligned `Alt+C close` / `Alt+T auto` hints to a new
  module hook `statusText` extension that gates only when chat is
  open.
- Add a `renderCompactExec(rt, w, turn)` that emits `$ <cmd>`
  one-liner and either inlines output OR collapses to `└─ N lines`
  based on whether `cfg.inline_observation_compact` is on.
- New `cfg.chat_chrome_style = .minimal | .full` (default `.minimal`).

### Tradeoffs

- Loses the "atty chat" label brand. The user pays attention to what's
  in the panel, not its frame.
- The right-aligned hint is small; first-time users might miss `⌥C
  close`. Mitigated by `Alt+H` cheat-sheet remaining the source of
  truth.
- Auto-mode indicator moves to statusbar — slight discoverability
  cost when the user is already focused IN the panel and might miss
  the segment swap.

---

## Proposal B — Card-per-turn

**Premise:** the conversation IS the UI. Each turn becomes a
self-contained card with a subtle background tint to separate it
from the shell scrollback above.

### What the user sees

```
─── atty chat · opus ──────────────────────────────────────

  ╭ You ────────────────────────────────────────────╮
  │ rebuild the failing test fixture for the parser │
  ╰─────────────────────────────────────────────────╯

  ╭ atty · exec ────────────────────────────────────╮
  │ I'll regenerate it from the seed JSON.          │
  │                                                 │
  │   $ python scripts/gen_fixture.py --seed …      │
  │   └── 8 lines · ⌥⇧C                             │
  ╰─────────────────────────────────────────────────╯

  ❯ |
```

- Each turn is a rounded-corner box. User card has `You` header;
  assistant cards have `atty · <action>` (`exec`, `done`, `question`).
- Card edges in 256-color dim grey; interior background optionally a
  one-shade-darker tint (terminal-dependent, gracefully degrades).
- Multi-line user turns wrap inside the card; the right edge of the
  card never crosses terminal width.

### Implementation

- New `paintCard(rt, w, kind, body, width)` helper that emits
  `╭─ <label> ─╮`, body lines wrapped + padded, `╰─╯` footer.
- `paint_chrome_tests.zig` extends to pin "card edges align under
  varying terminal widths."
- Card mode requires the terminal to render Unicode box-drawing
  glyphs cleanly (most do; gracefully degrade to ASCII `+--+`
  fallback for the rare ones that don't).

### Tradeoffs

- Visually rich; bigger discoverability win (the layout SAYS
  conversation).
- Costs ~2 extra rows per turn (top + bottom edge). For terminals
  near the floor, the inline panel can show fewer turns. Mitigated by
  the existing override-clamp + auto-resize.
- Wide turns wrap; long lines never overflow the card. Implementing
  the wrap correctly needs a width-aware tokenizer (we have one in
  `paint_width.zig`; reuse).
- Box-drawing chars cost ~3 bytes each at the seams. Paint buffer
  size unchanged (already 16 KB).

---

## Proposal C — Two-pane (transcript + composer)

**Premise:** the chat is a programming activity. Split the panel
horizontally — transcript on top (scrollback only), composer on
bottom (input + meta). They never compete for space.

### What the user sees

```
─── atty chat · opus ─────────────────── ⌥T auto · ⌥M model ─
                                                              
  You    rebuild the failing test fixture for the parser     
  atty   I'll regenerate it from the seed JSON.              
  $ python scripts/gen_fixture.py --seed parser.json         
                                                              
  ─── compose ─────────────────────────── 5/2048 · ⏎ send ────
  ❯ perfect, push to main when greenfield_|
```

- Top section: transcript only, scrolls independently
  (PageUp/PageDown already supported).
- Bottom section: composer with its own thin divider, a right-aligned
  `5/2048` byte counter (current input bytes / `chat_input_buf` cap),
  and a `⏎ send` reminder. Composer area can be one or many rows
  (multi-line input expands DOWN; transcript shrinks correspondingly
  but is capped at min 3 rows).

### Implementation

- Split `paintInputBlock` into `paintTranscriptBlock` (scrollback
  only) and `paintComposerBlock` (divider + counter + input). Refactor
  `paintInlineChat` to call both with a configurable split row.
- The composer height becomes a derived value: `1 + newlines(buf)`
  capped at `panel_rows / 2`. Transcript gets the remainder.
- Composer's bottom divider is a new chrome row; pre-existing
  divider at the top stays.

### Tradeoffs

- Best for power users with multi-line prompts (post-PR-#390 those
  exist now).
- Eats one extra row of chrome for the composer divider.
- The byte counter is a "you typed this much" affordance — useful
  feedback but mild noise. Could gate on `cfg.chat_show_byte_counter`.
- Two-section layout looks visually heavier than Proposal A.

---

## Proposal D — Progressive disclosure

**Premise:** the panel starts MINIMAL and reveals affordances
contextually as the user does things. Combines A's clean look with
B's structured turns when needed.

### Trigger map

| Trigger | Reveals |
|---|---|
| Panel first opens, empty | Just a `❯ |` cursor + dim hint `type to chat · ⌥H help` |
| User types `?` first | Auto-expand into question-pickerlist mode (already partial today). |
| LLM emits `.exec` | Compact `$ <cmd>` line, no card. Command captures? Show inline `└─ stdout` if ≤2 rows; collapse to `└─ N lines · ⌥⇧C` otherwise. |
| LLM emits `.done` | `✓ <reason>` one-liner, dim. No box. |
| LLM emits `.question` | Pick-list overlays the input row; free-text row stays at bottom. |
| Long assistant turn (>5 rows) | Auto-collapse to first 3 rows + `· … +N more · ⌥⇧C` indicator. |
| Soft-failure (timeout) | Existing retry banner (already implemented). |
| Tool errors | Inline `⚠ <reason>` dim red, no banner. |

### Implementation

- Add `cfg.chat_collapse_long_turns = true` + a `compact_render`
  pass in `paintInlineChat` that walks turn buf, computes row count,
  applies collapse threshold.
- Compose with the existing question pick-list intercept; the
  affordance for `?`-detection is a new `onInput` gate.
- Empty-panel hint is a single dim row painted only when
  `turns_len == 0` AND `chat_inline_input_len == 0`.

### Tradeoffs

- Pleasant out-of-box experience (the panel doesn't look intimidating).
- Heuristics carry risk: collapsing an assistant turn might hide
  something the user wanted to see. Mitigation: `Alt+Shift+C`
  expands to the full overlay where collapsed turns render in full.
- The `?` trigger could conflict with users wanting to literally
  type "?" at the start of a prompt; need an escape (e.g. `\?` or
  a delay).

---

## Proposal E — Status sidecar (status segments, not new rows)

**Premise:** the panel chrome is already optimal — the noise is in
the statusbar. Re-architect so the panel's metadata (auto state,
provider, send-key reminder, in-flight indicator) lives as
right-aligned segments in the statusbar, not as panel chrome.

### What the user sees

The panel itself reverts to a simpler version of today's chrome —
divider with `chat · opus` only, scrollback, input row with `❯ `.
But the statusbar gains a `chat` segment cluster:

```
[atuin] ✱ master ▴2 ▾1 │ chat:auto · opus · thinking… · ⌥H help
```

- `chat:` prefix marks the cluster as panel-scoped.
- `auto` / `dialog` swaps based on `auto_mode_active`.
- `opus` is the provider.
- `thinking…` only appears while `in_flight`.
- `⌥H help` reminder at the right.

### Implementation

- New `provideStatusSegments` hook on the LLM module that returns a
  list of segment specs (color, text, gate).
- Statusbar widens its segment vocabulary to allow space-separated
  multi-token segments with internal styling.
- Existing per-row chrome (icon + label + provider + hints) is
  removed from `paintInlineChat`.

### Tradeoffs

- Panel chrome becomes nearly invisible — the user reads the
  statusbar for "what mode am I in" instead of glancing at the panel
  divider.
- Statusbar gets busier — could clash with other modules (atuin,
  guardrail). Mitigation: panel chat segment only renders while
  `chat_inline_open`.
- Requires statusbar refactor; touches more code than the others.

---

## Proposal F — Margin gutter (left rail)

**Premise:** the noisiest part of today's chrome is per-row author
labels mid-text. Lift them into a fixed 4-char left margin so the
body has a clean leading edge and continuation lines naturally hang
off the rail.

### What the user sees

```
─── chat · opus ──────────────────────────────────── ⌥C close ─

 you │ rebuild the failing test fixture for the parser
 atty│ I'll regenerate it from the seed JSON.
     │   $ python scripts/gen_fixture.py --seed parser.json
     │   ✓ wrote tests/fixtures/parser.json (8 lines)
     │
 you │ perfect, push
 atty│ pushing now
     │   $ git push origin main
     │   ✓ pushed to origin/main
     │
   ❯ │ |
```

- 4-character gutter on the left (`you ` / `atty` right-aligned),
  followed by a vertical rail (`│`).
- Body always starts at column 6; the gutter+rail visually anchors
  the conversation.
- Continuation lines (multi-line user input, exec output, status
  indicators) have a blank gutter — the rail keeps the eye moving
  down without the noise of repeated labels.
- Input row prompt glyph (`❯`) lives in the gutter slot.

### Implementation

- New `gutter_width: u8 = 5` in `Config`.
- `paintInputBlock` walks turns; for each line within a turn, emits
  the gutter (label OR blank), then `│ `, then the body.
- The rail uses a dim 256-color escape (`\x1B[2;38;5;243m│\x1B[0m`)
  so it visually recedes while still anchoring.

### Tradeoffs

- Clean and structured; great for "I scan a long conversation."
- Costs 6 columns of body width permanently. On 80-col terminals that
  shrinks the typing area to ~70 cols. Mitigated by the existing
  long-line wrap in `paint_width.zig`.
- Doesn't help with vertical density (each turn still takes ≥1 row);
  pairs naturally with Proposal A's other simplifications.

---

## Proposal G — Timeline rail

**Premise:** the conversation IS a thread of turns + sub-actions
(LLM proposes `exec`, shell runs it, output flows back). Render that
structure explicitly with a vertical timeline and T/L junctions.

### What the user sees

```
─── chat · opus ──────────────────────────────────── ⌥C close ─

  ◆ you  rebuild the failing test fixture for the parser
  │
  ◇ atty I'll regenerate it from the seed JSON.
  ├──$ python scripts/gen_fixture.py --seed parser.json
  └──✓ wrote tests/fixtures/parser.json (8 lines)

  ◆ you  perfect, push
  │
  ◇ atty pushing now
  ├──$ git push origin main
  └──✓ pushed to origin/main

  ❯ |
```

- `◆` user turn / `◇` assistant turn nodes at the rail.
- `├──` for "still more to come in this turn" (intermediate exec or
  observation).
- `└──` closes the assistant's turn (last action).
- Plain `│` between turns spaces them visually.

### Implementation

- `paintTurnNode(w, kind, is_last)` helper that emits the right
  prefix glyph based on whether more turns/actions follow.
- Requires the painter to look one turn ahead (or a two-pass walk:
  count actions in this turn, then render with junction kind).
- Works gracefully on terminals that lack the geometric glyphs (fall
  back to `*` / `o` / `+--` / `+--`).

### Tradeoffs

- Most "structured" of the proposals — answers "which exec belongs
  to which turn" at a glance.
- Costs ~1 extra column for the rail. Glyph density is moderate;
  feels rich without being noisy.
- Look-ahead requirement adds one pass through the turn buffer at
  paint time. Cheap (turns are small) but a new computational
  pattern.

---

## Proposal H — Magazine typography

**Premise:** terminals can do typographic hierarchy too — bold,
underlines, color, whitespace, rules. Treat the conversation like a
magazine spread where each turn has a clear visual weight.

### What the user sees

```
─── ATTY CHAT · opus ──────────────────────────── ⌥C close ─

  YOU       rebuild the failing test fixture for the parser

  ATTY      I'll regenerate it from the seed JSON.
  ──────
            $ python scripts/gen_fixture.py --seed parser.json

            ┌─ output ──────────────────────────────────┐
            │ Wrote tests/fixtures/parser.json (8 lines)│
            └───────────────────────────────────────────┘

  YOU       perfect, push

  ATTY      pushing now
  ──────
            $ git push origin main
            ✓ pushed to origin/main

  ❯ |
```

- Bold uppercase author labels in a fixed-width slot (~10 cols).
- Assistant turns get a thin rule (`──────`) under the label,
  reinforcing "this is a section."
- Captured output rendered inside a soft box for visual separation
  from prose.
- Generous interline whitespace; conversations breathe.

### Implementation

- Config knob `chat_typography: enum { compact, magazine } = .compact`
  with `.compact` matching today's behavior.
- `paintMagazineTurn(w, turn)` is a new ~30-line helper that emits
  label + rule + indented body.
- Output box is the same drawing logic as Proposal B's card; share
  the helper.

### Tradeoffs

- Most readable of the proposals — easy on the eye, well-suited to
  long conversations the user reviews later.
- Most vertical-space-hungry: 3-4 rows per turn before content. On
  small terminals (≤20 rows) it eats the panel fast. Mitigation:
  collapse magazine mode to compact when `panel_rows < 12`.
- Color-blind/mono terminals lose the rule + label color hierarchy.
  Mitigated by the bold-uppercase fallback that still reads cleanly.

---

## Proposal I — Ticker mode (single-row, ambient)

**Premise:** for power users in deep auto-mode flow, full chat panel
is overkill. Show ONE row above the statusbar with the latest
assistant action; scroll left to fade older turns.

### What the user sees

```
$ make build
… (shell output continues)
…
─── chat · opus · ◯you rebuild fixture · ◉atty ✓ wrote 8 lines · ◯you push · ◉atty ✓ pushed · ❯ │
[atuin] ✱ master ▴2 ▾1 │ ⌥M opus · ⌥H help
```

- ONE reserved row above the statusbar.
- Turn ring rendered horizontally: `◯you <prompt summary> · ◉atty
  <action summary>`. Truncated to fit; older turns slide left and
  fade dim.
- `❯` cursor at the right edge — type to compose.
- `Alt+Shift+C` opens the full overlay to see the actual conversation
  history.

### Implementation

- `cfg.chat_chrome_style = .ticker` (new variant).
- `paintTickerRow(w, rt, total_cols)` walks turns from newest backward,
  summarizing each as `<icon> <kind> <first-N-bytes>·`, until the
  width budget runs out.
- Composer is the same horizontal-line input as today but rendered
  inline after the last turn segment.

### Tradeoffs

- Most space-efficient — single row, no DECSTBM growth.
- Only viable for users in auto-mode who don't actively read mid-flow.
  Dialog-mode users will find it cramped.
- Turn summary heuristics (first N bytes, trailing `…`) can lose
  context. Mitigated by the `Alt+Shift+C` escape hatch.
- Composer's typing area is bounded by the leftover after the turn
  summary — wraps awkwardly on long prompts.

---

## Proposal J — Floating composer (no reservation)

**Premise:** the inline panel's biggest cost is the permanent
DECSTBM reservation — it shrinks the shell's usable height even
when chat is idle. Float a composer over the cursor while focused;
let transcript live in shell scrollback like any other command's
output.

### What the user sees

```
$ ls -la                                    ← shell output unchanged
total 24
drwx... .
drwx... ..
-rw-r-- README.md

$ # (shell prompt unaffected)
                                            ← floating box appears
   ┌─ chat · opus ──────────────────────┐     below cursor while
   │ ❯ rebuild the failing test fixture │     focus is in chat;
   │                       1/4096 ⏎ send│     vanishes when not.
   └────────────────────────────────────┘

$ █                                         ← cursor stays here
                                            ← transcript prints
                                              into scrollback when
                                              LLM responds:
You: rebuild the failing test fixture for the parser
atty: I'll regenerate it from the seed JSON.
$ python scripts/gen_fixture.py --seed parser.json
✓ wrote tests/fixtures/parser.json (8 lines)

$ █                                         ← back at shell
```

- No DECSTBM reservation. Composer is a small box rendered
  ON-DEMAND below the shell's prompt row, only when chat is focused.
- LLM responses print into shell scrollback like a normal command's
  output (with a small `You: …` / `atty: …` prefix).
- `Alt+C` opens the composer; pressing Esc or running an exec
  closes it and lets the response stream into scrollback.

### Implementation

- New `paintFloatingComposer(w, rt, anchor_row, anchor_col)` that
  positions a small box (5 rows × 40 cols) below the shell's
  current prompt row. Saves/restores cursor via DECSC/DECRC.
- Turns print to shell stdout (not pty.master) via `provideTermBytes`
  with a one-shot `\x1B[?25l … \x1B[?25h` cursor hide/show wrapper.
- No more reservation arithmetic; no clamp logic; no scrollback
  windowing inside the panel.

### Tradeoffs

- Most disruptive to today's architecture: removes the reservation
  scheme entirely, removes scrollback semantics inside a panel,
  changes how turns interact with shell history.
- Cleanest end result: chat feels like it belongs to the shell, not
  to atty.
- Loses the "shell stays visible above the panel" invariant the
  inline mode is built on; the user sees shell scrollback AND chat
  scrollback intermixed. Some users will love this, some will hate
  it. Add `cfg.chat_chrome_style = .floating` and let the user opt
  in.
- The "↻ Enter retry" banner has nowhere to render — would need
  the full overlay or a one-shot scrollback line.

---

## Recommendation

Start with **Proposal A** (minimal mode). It's the smallest scope —
mostly subtractive — and lays the groundwork that any of the others
can layer on top of (e.g. B's cards become an opt-in `chat_chrome_style
= .card` after A ships; D's progressive disclosure becomes a layer
above A's clean baseline; E's status sidecar lives orthogonally to
the panel chrome).

If A feels too sparse after dogfooding, layer D's progressive
disclosure — keep the minimal frame, but add empty-state hint,
question pick-list affordance, and collapse for long turns. That
gives the best balance of "clean and clear" with "discoverable."

The newer batch (F-J) sit along orthogonal axes:

| Want | Pick |
|---|---|
| Clean leading edge, structured scanning | F (margin gutter) |
| Visualise turn/sub-action threading | G (timeline rail) |
| Typographic hierarchy for long review sessions | H (magazine) |
| Minimal vertical footprint in auto-mode | I (ticker) |
| Chat blends into shell scrollback, no DECSTBM | J (floating) |

F and G compose well with A's stripped-down chrome (use A's divider
+ F's gutter for "clean + scannable"). H is the heavyweight option
for users who'd rather read than skim. I and J are radical
departures — best as opt-in `chat_chrome_style` variants rather
than the default.

---

## Implementation seam — common to all proposals

All ten proposals share a small refactor of `paintInputBlock` (in
`src/modules/llm/paint.zig`) into composable chrome helpers:

```zig
fn paintChromeDivider(w, rt, kind, total_cols) !void { … }
fn paintTranscriptBlock(w, rt, top_row, bot_row) !void { … }
fn paintComposerBlock(w, rt, row, kind) !void { … }
```

Today `paintInputBlock` is monolithic and handles input + chrome +
multi-line walking in one function. Split it first; then each
proposal's UI variant is a different combination of those helpers
plus a small render-mode flag in Config. The split is also a
prerequisite for the test-side regression coverage (`paint_chrome_tests`
already lives in its own file post-#399).

## Out-of-scope notes (for the next round)

- **Mouse support.** None of these proposals need it; `mouse_links`
  and `mouse_urls` already cover the click-on-token cases. A future
  proposal could add `mouse_chat` (click on `Alt+M` segment to cycle
  model) but it's a separate axis.
- **Themes.** All proposals use the existing palette (dim grey edges,
  cyan for chat, orange for retry, red for errors). A `cfg.chat_palette`
  knob that picks among 2-3 curated palettes (mono / catppuccin /
  nord) is a clean follow-up once the layout is settled.
- **Layouts.** Vertical-split layouts (chat on the right half of the
  terminal) are explicitly NOT proposed — they fight tmux/zellij
  splits and break the "shell-stays-visible-above-panel" invariant
  the inline mode depends on.
