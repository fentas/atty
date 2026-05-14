//! split_csi_no_corruption — regression guard for the LazyVim
//! "5;207;255mFind File" artifact that appeared briefly while the
//! synchronized-output (DECSET ?2026) wrap was being prototyped on
//! this PR (since reverted).
//!
//! Failure mechanism: an inner TUI's CSI sequence gets split across
//! two PTY reads (e.g. nvim writes `\x1B[38;` then `5;207;255mFoo`
//! on separate flushes). If atty had emitted any extra escape
//! sequence (`\x1B[?2026h\x1B[?2026l`, or anything else starting
//! with `\x1B[`) BETWEEN those reads, the terminal would see
//! `\x1B[38;\x1B[…\x1B[…5;207;255mFoo`, abort the SGR on the new
//! `\x1B[`, and render the trailing params as literal text.
//!
//! General invariant the scenario pins: atty must not emit any
//! bytes between an inner program's split-across-reads writes
//! UNLESS those bytes are part of an overlay paint that the
//! upstream pipeline has chosen to interleave. We reproduce the
//! split with `printf` + sleep and assert the SGR is honoured
//! (no literal params on the visible grid).
//!
//! Statusbar disabled so no overlay paint runs at all — the
//! ONLY motion between the two halves is whatever atty inserts
//! on its own. Pre-revert (when the wrap fired unconditionally
//! per tick) this scenario consistently corrupted; post-revert
//! it renders cleanly.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
};
