//! nvim_startup_replay — feed atty a captured byte stream from
//! `nvim -u NONE` (no plugins, no LazyVim) startup and snapshot the
//! resulting grid. Smoke test that atty doesn't corrupt nvim's
//! output stream.
//!
//! Fixture at `tests/e2e/fixtures/nvim-startup-4k.bin` is the first
//! ~4KB of master output captured by running nvim under a Python
//! pty.openpty wrapper with TERM=xterm-256color and a fixed 80x24
//! size. Includes the alt-screen enter, DECRQM capability probes,
//! and the initial draw of the welcome screen.
//!
//! The e2e harness's vt-grid IGNORES `\x1B[?1049h`, so nvim's alt-
//! screen content lands on the main grid — visually weird but
//! perfectly deterministic for regression purposes. A future
//! corruption (whether in cursor_tracker's CSI parsing or any
//! other byte-touching change) would show up as the captured
//! grid drifting from the golden.
//!
//! Statusbar disabled so no overlay paint races with the replay.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
};
