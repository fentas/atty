# Image paste into the chat panel — research

How popular terminals expose pasted images to a TUI, what Claude Code actually
does, and the smallest viable path for atty's chat panel.

## Terminal landscape

| Terminal  | Bracketed paste | Drag-drop emits `file://` URI | Reads OSC 52 (text) | Reads OSC 5522 (image) |
|-----------|-----------------|-------------------------------|----------------------|------------------------|
| kitty     | yes             | yes (path, quoted)            | yes (opt-in)         | **yes — only one**     |
| Ghostty   | yes             | yes (macOS reliably; Linux flaky) | yes              | parses, doesn't reply (1.3.0) |
| WezTerm   | yes             | yes (`quote_dropped_files`)   | write-only by default | no                    |
| Alacritty | yes             | partial (#5937 quotes paths)  | write-only           | no                     |
| foot      | yes             | yes                           | yes                  | no                     |
| iTerm2    | yes             | yes (path)                    | yes                  | no                     |

**Critical distinction.** kitty graphics, Sixel, and iTerm2 `OSC 1337;File=`
are all **one-way** TUI -> screen. None carries clipboard image data **into**
the TUI. The only standardised inbound path is **kitty's OSC 5522** (OSC 52
+ MIME field). As of mid-2026 kitty is the sole terminal that implements the
read direction; Ghostty parses but doesn't respond ([Ghostty #8275](https://github.com/ghostty-org/ghostty/discussions/8275)).
OSC 52 itself is text-only. Bracketed paste carries whatever bytes the
terminal chose to send; when the clipboard is image-only, every terminal
except kitty drops the paste silently — no `\x1B[200~` frame is emitted.

## What Claude Code actually does

Confirmed from issues [#29204](https://github.com/anthropics/claude-code/issues/29204),
[#42712](https://github.com/anthropics/claude-code/issues/42712), [#58133](https://github.com/anthropics/claude-code/issues/58133)
and writeups ([invoke.dev](https://getinvoke.dev/learn/screenshot-paste-claude-code-terminal/)):

On `Ctrl+V` it shells out — `pngpaste` (macOS), `xclip -selection clipboard
-t image/png -o` (X11), `wl-paste -t image/png` (Wayland), PowerShell
(Windows) — base64s the PNG and attaches it. **No terminal protocol carries
the image bytes.** It also reads a literal path / `file://` URI from
drag-drop directly. Over SSH the subprocess approach breaks (no display
server, plus a PTY race with `xclip`), which is why [#42712](https://github.com/anthropics/claude-code/issues/42712)
asks for OSC 5522.

## Recommendation for atty — phased

**Phase 1 — file URI / path detection inside bracketed paste (a day).**
In `src/modules/llm/hooks.zig`, when `paste_active` ends, scan the accumulated
buffer. If it parses as `file://...` or an absolute path with extension
`.png|.jpg|.jpeg|.gif|.webp` under `max_image_bytes`, swap the inserted text
for an attachment on the chat turn. Covers Ghostty/macOS, WezTerm, iTerm2,
Alacritty drag-drop — the dominant real-world UX. Zero new deps.

**Phase 2 — explicit `Alt+V` clipboard-image binding (a few days).**
New `Action.chat_paste_image`. Worker thread spawns `wl-paste -t image/png` /
`xclip -selection clipboard -t image/png -o` / `pngpaste -`. Probe with
`wl-paste -l` / `xclip -t TARGETS -o` first to distinguish "no image" from
"tool missing"; surface that distinction in `atty doctor`. atty's PTY fork
gives the subprocess a clean fd set — no `/dev/tty` race like Claude Code's.

**Phase 3 — OSC 5522 in-process (the SSH story).** Send
`\x1B]5522;type=read;<b64("image/png")>\x1B\\` and read chunked
`status=DATA:...` replies off our terminal fd. Only kitty answers today;
Ghostty's PR is in flight. Fits next to atty's existing OSC 133 handling
and is the only mechanism that survives SSH without a forwarded clipboard.
Probe terminfo / `TERM` so non-supporting terminals fall back to Phase 2.

Add `Config.image_paste = .{ .enabled, .max_bytes, .allowed_mime }` — chat
content goes to the LLM and some users will want a hard off switch.

## Primary sources

- kitty graphics protocol — https://sw.kovidgoyal.net/kitty/graphics-protocol/
- kitty clipboard (OSC 5522) — https://sw.kovidgoyal.net/kitty/clipboard/
- Ghostty OSC 5522 discussion — https://github.com/ghostty-org/ghostty/discussions/8275
- Claude Code OSC 52/5522 RFE — https://github.com/anthropics/claude-code/issues/42712
- xterm bracketed paste — https://invisible-island.net/xterm/xterm-paste64.html
- WezTerm `quote_dropped_files` — https://wezterm.org/config/lua/config/quote_dropped_files.html
- wl-clipboard man page — https://man.archlinux.org/man/wl-clipboard.1.en
