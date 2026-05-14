//! DCS 2026 — synchronized output mode (mintty / iTerm2 / Kitty / WezTerm /
//! Ghostty extension). Wrap multi-region writes in `\x1B[?2026h` … `\x1B[?2026l`
//! so the terminal buffers all updates between begin and end and applies them
//! as a single frame.
//!
//! Why: atty paints up to three overlays per tick — ghost-clear, statusbar,
//! ghost-paint — as separate `writeAll` calls. On slow terminals (SSH'd
//! sessions, web-terminals, JetBrains' built-in TTY) the user can see those
//! land as distinct redraws, especially mid-frame artifacts when the
//! statusbar repaint races with a fresh keystroke echo. Wrapping the per-
//! tick render block atomizes the frame and removes the flicker.
//!
//! Terminals that don't implement 2026 see the private-mode set/reset as
//! "unknown private mode" and silently ignore both bytes — there's no
//! capability check needed, the fallback is just "render as before".
//!
//! Pattern lifted from bubbletea's `cursedRenderer.flush`
//! (cursed_renderer.go:528-558). See `docs/research/huh-vs-atty.md` for
//! the comparison that surfaced this.

pub const begin = "\x1B[?2026h";
pub const end = "\x1B[?2026l";
