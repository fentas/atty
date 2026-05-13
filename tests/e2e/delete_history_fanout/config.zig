//! delete_history_fanout — TWO history modules wired side by side.
//!
//! Regression scenario for PR #8: `dispatchDeleteHistoryMatch` used
//! `try`, so the first module's deletion outcome propagated through
//! the inline-for and could short-circuit subsequent modules. The fix
//! catches per-iteration; this scenario proves the walker reaches both
//! implementers by checking that BOTH backing files lose the recorded
//! line after a single Ctrl+Shift+D.
//!
//! Two distinct paths (different `.path`) make `configure(...)` mint
//! two distinct types, so the comptime tuple actually carries two
//! independent runtime instances rather than collapsing into one.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.history.configure(.{
        .path = "/tmp/atty-e2e-fanout-A",
        .format = .plain,
        .capacity = 32,
    }),
    atty.modules.history.configure(.{
        .path = "/tmp/atty-e2e-fanout-B",
        .format = .plain,
        .capacity = 32,
    }),
};
