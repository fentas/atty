//! altscreen_full_rows — regression guard for the LazyVim-shaped bug
//! where a TUI queried TIOCGWINSZ at startup, saw the slimmed slave
//! size that atty handed it for statusbar reservation, and drew its
//! UI for that smaller box. Even after atty later resized to FULL on
//! `\x1b[?1049h` + SIGWINCH, dashboard-style plugins (alpha-nvim,
//! dashboard.nvim) don't always redraw, so the splash stayed
//! mis-centered.
//!
//! Fix shape: slave always reports FULL rows; DECSTBM keeps shell
//! scrolling out of the reserved zone, so the bash side still works.
//! This scenario hard-pins that contract by running `tput lines`
//! in bash — pre-fix it would print `effectiveRows()` (rows minus
//! reserve_rows); post-fix it prints the full row count. We don't
//! drive an alt-screen TUI here — the e2e harness's vt grid
//! ignores `\x1b[?1049h`, so alt-screen byte effects (including
//! the DECSTBM-reset emission) aren't visible to snapshots.
//! Real-Ghostty validation of the TUI side happens manually.
//!
//! Statusbar enabled so the slimmed-vs-full distinction is real
//! (with statusbar off the slave is always full anyway).

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
};

pub const statusbar: atty.StatusBar = .{
    .enabled = true,
    .reserve_rows = 3,
    .base_text = "atty",
};
