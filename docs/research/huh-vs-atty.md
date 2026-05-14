# huh vs atty: cursor, rendering, positioning, footer, DSR

Research target: charmbracelet/huh (Go TUI form library) cloned into `/tmp/huh-research`, with its rendering layer in `/tmp/bubbletea` (charmbracelet/bubbletea) and the cell-buffer / event-parser layer in `/tmp/uv` (charmbracelet/ultraviolet). atty source lives at `/home/fentas/github/fentas/atty/src/`.

## Summary

huh itself owns essentially zero terminal-positioning logic; it produces a single string per `View()` and hands the whole frame to bubbletea, which diffs against an in-memory cell buffer and emits minimal cursor moves via the ultraviolet `TerminalRenderer`. In inline (non-altscreen) mode bubbletea uses **relative cursor movement only** and never absolute positioning, which is the directly applicable pattern for atty's dynamic-statusbar idea. DSR (`\x1b[6n`) is fully delegated: ultraviolet's CSI decoder produces `CursorPositionEvent`, bubbletea wraps it in `CursorPositionMsg`, and huh never calls `RequestCursorPosition` — its design avoids needing the terminal's cursor state at all because it owns the cell grid. The most transferable pattern for atty is bubbletea's **inline-mode frame model**: track frame height in cells, scroll up with `\n` to reserve rows, render with relative moves, restore via `CursorUp` — never query the cursor, never use absolute CUP. For atty's "filter DSR replies so the shell never sees them" problem there's no precedent in huh (it doesn't sit in front of another process), but bubbletea's `DECXCPR` workaround (`uv/decoder.go:455`) shows the F3-vs-DSR ambiguity is a real wire-level pitfall.

## How huh handles each concern

### Cursor tracking

huh stores a logical cursor index per field (e.g. `MultiSelect.cursor` at `/tmp/huh-research/field_multiselect.go:40`, manipulated with simple arithmetic at `:394`, `:403`, `:484`). For text input it delegates entirely to `bubbles/textinput` (`/tmp/huh-research/field_input.go:33,361,412`). There is no DSR query and no `\x1b[6n` anywhere in huh's tree — `grep -rn "Cursor" /tmp/huh-research/*.go` shows only style + logical indices. The actual terminal cursor X/Y is set by bubbletea **per frame** in `cursedRenderer.flush()` via `s.scr.MoveTo(view.Cursor.X, view.Cursor.Y)` at `/tmp/bubbletea/cursed_renderer.go:466`, computed from the `*Cursor` field on `tea.View` (`/tmp/bubbletea/tea.go:131,357-381`).

### Rendering

huh builds an entire frame string per call. `Form.View()` (`/tmp/huh-research/form.go:654-660`) returns `f.styles().Base.Render(f.layout.View(f))`, which recursively concatenates each `Group.View()` (`group.go:366-384`), which concatenates header + viewport.View() + footer joined by `"\n"`. Field views (`field_input.go:380-418`) likewise build a `strings.Builder` from title/description/textinput parts. There is no diff at this layer.

The diff happens one layer down: `cursedRenderer.flush()` at `/tmp/bubbletea/cursed_renderer.go:257-576` copies the new content into an off-screen `cellbuf` (`uv.ScreenBuffer`) via `content.Draw(s.cellbuf, ...)` at `:311`, then `s.scr.Render(s.cellbuf.RenderBuffer)` at `:461` computes the minimum set of cell-by-cell updates against the previous frame. A fast-path `viewEquals` at `:287` makes the no-op case zero bytes. Synchronized output mode (DCS 2026) wraps multi-region updates atomically when supported (`:528-558`).

### Positioning

In inline (non-altscreen) mode bubbletea uses **only relative movement**. `reset()` at `/tmp/bubbletea/cursed_renderer.go:597-598` calls `scr.SetRelativeCursor(true)` + `scr.SetFullscreen(false)`. The renderer emits `CursorUp/Down/Left/Right` (and optional hard-tab / backspace optimization, see `setOptimizations` at `:59-72` and the `relativeCursorMove` helper at `/tmp/uv/terminal_renderer.go:1305`). Absolute CUP (`\x1b[<r>;<c>H`) is only used in fullscreen/altscreen mode (`EnterAltScreen` at `/tmp/uv/terminal_renderer.go:282`).

The inline frame is **height-fluid**. At `cursed_renderer.go:269-280` the renderer recomputes `frameArea.Max.Y` from `content.Height()` every flush, then if the frame grew it scrolls via `\n`s (see `insertAbove` at `:706-763` for the canonical "scroll up by N + cursor back up by N + draw + cursor down" pattern). The frame area shrinking forces a full redraw (`s.scr.Erase()` at `:296`). At end-of-frame in inline mode the renderer guards against dangling at column N-1 to avoid spurious wraps (`:467-477`).

huh uses `lipgloss.JoinHorizontal/JoinVertical` (`/tmp/huh-research/layout.go:83,160`) for multi-group layouts but only as **pure string composition**; the resulting string still goes through bubbletea's renderer for actual positioning.

### Status / footer area

huh's footer is **part of the same frame string** as the main content — there is no separately-rendered region. `Group.View()` at `/tmp/huh-research/group.go:366-384` appends `g.Footer()` (which renders short-help via `g.help.ShortHelpView(...)` at `:397` plus any error messages at `:399-405`) after the main viewport with `\n\n` as a gap. The footer is recomputed every frame; resize triggers a `Group.WithHeight()` recompute at `form.go:539-560` which adjusts viewport height by `titleFooterHeight()` (`group.go:349-358`).

Notable detail: `Group.View()` trims trailing spaces from the last line (`group.go:380-382`) "because right-to-bottom-corner writes can scroll the view up on Apple Terminal". That's a precedent for the kind of "writing to the last cell scrolls" gotcha atty cares about.

There is no separate "always-on-bottom" reservation analogous to atty's DECSTBM-shrunk slave; in inline mode huh's frame just is what it is, and the prompt floats up via `\n` scroll when content grows. Altscreen mode is opt-in (`tea.View.AltScreen = true` per-frame, `cursed_renderer.go:319-329`) and there huh runs in a dedicated buffer — no shared region with anything.

### DSR handling

Three-layer story:

1. **huh never asks.** No `RequestCursorPosition` / DSR call in the entire tree.
2. **bubbletea has the API but doesn't use it on its own.** `tea.RequestCursorPosition()` at `/tmp/bubbletea/cursor.go:24-28` returns a `requestCursorPosMsg`; the event loop converts that to `ansi.RequestCursorPositionReport` at `/tmp/bubbletea/tea.go:855-856`. Replies arrive as `CursorPositionMsg{X,Y}` via the input event translator at `/tmp/bubbletea/input.go:18-19`.
3. **ultraviolet parses the wire reply.** `/tmp/uv/decoder.go:403-411` handles `?R` (DECXCPR / extended cursor position) and `:444-461` handles plain `R` (standard DSR). The plain-R branch has a comment-worthy quirk: it's **ambiguous with the `CSI 1 ; <mod> R` modified-F3 keypress**. When row=1 and col-1 ≤ all-mods-mask, ultraviolet emits a `MultiEvent{KeyPressEvent{F3...}, CursorPositionEvent{...}}` (`:457`) and the comment recommends `ansi.RequestExtendedCursorPosition` (DECXCPR) for unambiguous polling.

This last point is highly relevant for atty: any DSR-poll design needs to use **DECXCPR (`\x1b[?6n`)** rather than vanilla DSR (`\x1b[6n`) to avoid the F3 collision when filtering the shell-bound input stream.

## How atty handles the same

### Cursor tracking

atty doesn't track cursor coordinates at all — it has a logical input-line buffer in `LineState` (`/home/fentas/github/fentas/atty/src/line_state.zig`) plus an optional ground-truth capture between OSC 133 `;B` / `;C` markers (`/home/fentas/github/fentas/atty/src/osc133.zig:166-179`, `:239-262`). There is no X/Y model; everything rides on terminal-relative writes from save_cursor / restore_cursor.

### Rendering

Every overlay is a "save/paint/restore" sandwich around the shell's cursor. `Ghost.show()` at `/home/fentas/github/fentas/atty/src/ghost.zig:61-68` writes once and remembers the bytes; `Ghost.clear()` at `:73-78` writes the inverse. Statusbar paints likewise wrap in `ansi.save_cursor` / `ansi.restore_cursor` at `/home/fentas/github/fentas/atty/src/statusbar.zig:354,414`. There is no cell buffer — the comparison is byte-equality of the text just rendered (`statusbar.zig:345-351`) for idempotence. Every render is a "full paint" of just that region.

### Positioning

Mixed model:

- Statusbar paints with **absolute CUP** to the reserved rows: `\x1b[<rows>;1H\x1b[K` at `statusbar.zig:357,392`. Justified by the fact that DECSTBM has reserved a constant scroll region, so the bar rows have fixed coordinates.
- Ghost overlay uses **purely relative ops** wrapped in save/restore cursor (see `ansi.zig` writeGhost / writeClearGhost; `ghost.zig:61-78`).
- Ghost-list uses **relative moves**: LF×N to scroll the prompt up, `\x1b[<N>A` (CUU) to return, then `\x1b[1B\x1b[1G\x1b[K` for each row (`ghost_list.zig:125-176`). Same pattern as bubbletea's `insertAbove` (`/tmp/bubbletea/cursed_renderer.go:706-763`) — atty arrived at it independently.

### Status / footer area

The statusbar is a **terminal-region reservation** via DECSTBM, not a frame-level concern. `statusbar.activate()` at `statusbar.zig:255-264` emits `\x1B[2J` then `\x1B[1;<top>r` (DECSTBM) and the proxy slims the slave PTY's reported rows by `reserve_rows` so the shell wraps inside the visible region. The hint/error row sits at `effectiveRows() + 1` (`statusbar.zig:390-407`) — also CUP-absolute.

Alt-screen apps (vim, k9s, less) get the full terminal: the proxy resets DECSTBM on `?1049h` (`proxy.zig:1054`) and re-applies on `?1049l` via `sb.reactivate` (`statusbar.zig:292-301`, `proxy.zig:1063-1066`). Tracker: `/home/fentas/github/fentas/atty/src/altscreen.zig` — a CSI parser only looking for `?47|1047|1049 h/l`, with multi-mode DECSET handling (`altscreen.zig:115-126`).

SIGWINCH path at `proxy.zig:1098-1119` re-queries TIOCGWINSZ, updates the statusbar dims, re-emits `activate`, and propagates the FULL size to the slave (the `effectiveRows()` slimming is implicit via DECSTBM, not via the kernel-reported winsize, since modern TUIs query winsize on startup before responding to SIGWINCH).

### DSR handling

atty currently does NOT query DSR, does NOT filter DSR replies from the input stream, and has no parser for `\x1b[?6n` / `\x1b[6n` replies. The closest analogue is `keymap.isCsiU` (`/home/fentas/github/fentas/atty/src/keymap.zig:351`), which detects kitty-keyboard CSI-u sequences in stdin and drops the ones not bound to actions. A DSR-response filter would need a similar shape but on the master→stdout path (when atty itself queries) and would need to **not** drop legitimate DSR replies the shell asked for. There's no current code for this.

## Differences worth borrowing

1. **Inline-mode "scroll up to reserve rows" pattern** (small). Bubbletea's `insertAbove` (`cursed_renderer.go:706-763`) is the canonical recipe for "the prompt is wherever it is; add N rows of managed content above without losing what's there". atty's `GhostList.activate` already does this for inline pick lists (`ghost_list.zig:125-148`). The borrow: apply the same trick for a **statusbar reservation that floats with the prompt** instead of being pinned to the bottom via DECSTBM. Avoids the "the bar moves up when the user scrolls back" oddness of DECSTBM-pinned regions, and removes the need to slim the slave-PTY winsize. What breaks: the user would lose the "always-visible bottom strip" property; the bar moves with the prompt. Test plan: e2e scenarios with prompt at various screen positions, plus a scroll-back interaction test.

2. **Track a local cell-grid model** (large). The structural reason huh/bubbletea never need DSR is that ultraviolet's `ScreenBuffer` (`/tmp/uv/buffer.go:653+`) maintains a complete cell-for-cell mirror of the terminal. Diff is byte-cheap, no terminal round-trip. For the "dynamic statusbar that knows where the prompt is" idea, atty could keep a slim version: parse master→stdout for CUP/CUD/CUU/LF/CR/scroll events and maintain a single integer (the shell's cursor Y row). This avoids DSR entirely. What breaks: every CSI emitted by the shell now needs accounting — sloppy parsing miscounts and the bar paints in the wrong row. atty already has 3 CSI parsers (`altscreen.zig`, `osc133.zig`, `keymap.zig`); adding a 4th cursor-tracker is consistent with the style but is real code (~200 LOC + tests). Mid-effort if scoped to "track row only, not column". Test plan: e2e scenarios for every CSI movement family + a fuzzer.

3. **DECXCPR over DSR if/when polling becomes necessary** (small). ultraviolet's decoder (`/tmp/uv/decoder.go:444-461`) documents that vanilla `\x1b[6n` reply (`CSI <r>;<c> R`) is indistinguishable from a modified-F3 keypress (`CSI 1; <mod> R`) when row=1. Their recommendation: use `\x1b[?6n` (DECXCPR), which replies with `CSI ? <r>;<c>;<page> R` — the `?` prefix is unambiguous. atty should use DECXCPR if it ever queries; saves a future debugging session. What breaks: terminals that don't implement DECXCPR (some minimal ones) will just not reply. Test plan: e2e against xterm, kitty, ghostty, alacritty.

4. **Idempotent-by-content frame compare, but for the whole overlay set** (medium). Bubbletea's `viewEquals` (`cursed_renderer.go:803-843`) compares all view fields and short-circuits the whole flush when nothing changed. atty does this per-region (statusbar's `last_buf`, ghost's `rendered`, ghost_list's `set` returning false on no-change at `ghost_list.zig:77-86`) but each render path is called unconditionally from `proxy.zig`. A single "did anything change?" compare at the top of the per-tick render block (line ~415 in proxy.zig) would let the no-op tick emit zero bytes for the whole overlay set, not just per region. What breaks: probably nothing, but transient TTL expiry needs to remain a change-trigger (currently force-invalidates via `last_valid = false` at multiple sites; works correctly with the bubbletea-style fast path). Test plan: existing unit tests cover individual region idempotence; need a top-level "render block writes 0 bytes when nothing changed" assertion.

5. **Synchronized output mode (DCS 2026)** wrap for multi-region updates (small). `cursed_renderer.go:528-555` wraps all non-cursor-visibility updates in `\x1b[?2026h` / `\x1b[?2026l` when the terminal supports it, eliminating flicker between regions. atty currently emits ghost-clear + statusbar-paint + ghost-paint as separate writes within a single iteration; on slow terminals the user can see them as distinct redraws. Wrapping the per-iteration write set in 2026h/l would atomize them. What breaks: terminals that don't support 2026 just ignore the brackets; harmless. Need a capability check (atty can detect via $TERM or just try-and-hope — the unrecognized DCS is silently dropped on all common terminals). Test plan: e2e visual diff with a slow-printing scenario.

## What atty does better or differently for a reason

- **DECSTBM-reserved bottom region**: huh/bubbletea cannot do this because they assume they own the whole terminal or at least the bottom of an inline frame. atty's job is opposite: it's a proxy with the shell drawing freely, and DECSTBM is the cleanest mechanism to carve out persistent rows. Bubbletea's `insertAbove` is the closest analogue but is one-shot (writes lines and moves on); atty needs a sticky reservation. Don't replace this; the dynamic-position idea is additive ("statusbar at top OR bottom depending on prompt position"), not a replacement.

- **PTY-side filtering responsibilities**: huh sits at the terminal boundary, so it never has to "absorb a sequence so the downstream doesn't see it". atty's CSI-u dropper in `keymap.isCsiU` (`keymap.zig:351`) is a pure proxy concern with no huh equivalent. If atty adds DSR polling it'll need an analogous filter on the master→stdout path (drop DSR replies that atty queried, pass through DSR replies the shell queried for itself) — there's no precedent to borrow, design from scratch.

- **OSC 133-based input region capture** (`osc133.zig`): no analogue in huh — huh owns the input, doesn't try to recover it from the wire. The OSC-133 design is atty-specific and necessary because shells own the input rendering.

- **Compile-time module composition**: huh's `selector.Selector[Field]` (referenced from `group.go:21`) is a heterogeneous runtime collection. atty's `Dispatcher(config.modules)` with `inline for` (`dispatch.zig` per CLAUDE.md) eliminates all runtime branching on modules. Different tradeoffs, both correct for their domains; not a borrowable pattern in either direction.

- **No tea/lipgloss/colorprofile dependency chain**: huh pulls bubbletea + bubbles + lipgloss + ultraviolet + colorful + colorprofile. atty's `style.zig` + `ansi.zig` cover the same ground in ~300 lines because atty only ever paints a handful of overlays — never wraps content, never lays out a multi-region frame. Don't borrow lipgloss; atty's footprint is intentionally suckless.
