//! history_records_partial_osc133 — end-to-end check that
//! history.onLineCommit ACTUALLY writes to disk when the shell emits
//! only `;A` (Ghostty's partial OSC 133 shape).
//!
//! Companion to `ghost_partial_osc133`: that scenario proves the
//! GHOST OVERLAY renders; this one proves the RECORDING gate isn't
//! suppressing writes. Both regressed pre-PR #17 — `inInputPhase()`
//! returned false in `.at_prompt`, so the recording gate
//! (`osc.active && !inInputPhase()`) evaluated true and
//! `dispatchLineCommit` was skipped → ring + file stayed empty.
//!
//! No atuin module — just history pointing at a scenario-private
//! file. Statusbar off so the cat snapshot is clean.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.history.configure(.{
        .path = "/tmp/atty-e2e-history-records-partial-osc133",
        .format = .plain,
        .capacity = 32,
    }),
};
