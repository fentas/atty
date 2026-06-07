# Chat panel UI/UX proposals

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

---

## Implementation seam — common to all proposals

All five proposals share a small refactor of `paintInputBlock` (in
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
