//! ghost_partial_osc133 — end-to-end check that ghost text actually
//! paints when the shell emits a PARTIAL OSC 133 marker stream
//! (Ghostty's default `shell-integration-features = osc-133` is the
//! canonical case: emits `;A` and `;C` but never `;B` or `;D`).
//!
//! Why this test exists: PR #17's unit tests pin the predicate flip
//! (`inInputPhase()` returns true after `;A`) and the gate split
//! (`captureActive()` only true for `.in_input`). But unit tests
//! don't drive the proxy + history-module pipeline, so they can't
//! prove ghost text ACTUALLY shows up on screen. This scenario does:
//! record an entry THROUGH atty at a Ghostty-style `;A`-only
//! prompt (so history.onLineCommit fires under partial-OSC133
//! conditions and the in-memory ring picks it up — pre-seeding
//! the file alone wouldn't help; history reads at attach time
//! before this prompt exists), type a prefix, and snapshot the
//! grid expecting a dim trailing ghost.
//!
//! No atuin module (would add subprocess fan-out + flake) — just
//! history pointing at a scenario-private file. Statusbar off so
//! the snapshot grid carries only the prompt + ghost cells.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.history.configure(.{
        .path = "/tmp/atty-e2e-ghost-partial-osc133",
        .format = .plain,
        .capacity = 32,
    }),
};
