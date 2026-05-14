//! split_csi_no_corruption — regression guard for the LazyVim
//! "5;207;255mFind File" artifact that appeared after the DCS 2026
//! wrap was added in this PR.
//!
//! Failure mechanism: an inner TUI's CSI sequence gets split across
//! two PTY reads (e.g. nvim writes `\x1B[38;` then `5;207;255mFoo`
//! on separate flushes). If atty's per-tick wrap emits
//! `\x1B[?2026h\x1B[?2026l` BETWEEN those reads, the terminal sees
//! `\x1B[38;\x1B[?2026h\x1B[?2026l5;207;255mFoo`, aborts the SGR
//! on the new `\x1B[`, and renders the trailing params as literal
//! text.
//!
//! The fix gates the wrap on `tick_will_render` — when no overlay
//! would paint (alt-screen TUIs, or sessions with statusbar off),
//! the wrap is skipped. This scenario reproduces the split with
//! `printf` + sleep and asserts the SGR is honoured (no literal
//! params on the visible grid).
//!
//! Statusbar disabled so the only motion that could insert wrap
//! bytes between split reads is the tick path itself. Pre-fix this
//! scenario consistently corrupted; post-fix it renders cleanly.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
};
