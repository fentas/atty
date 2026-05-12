//! ghost_accept — atty built with the history module pointed at a
//! scenario-private file, so we can drive a recorded command and
//! verify both the dim ghost overlay AND that the bound key swaps
//! the keystroke for the suggestion bytes.
//!
//! Statusbar off so the snapshot grid doesn't carry the bar's
//! styling. atuin omitted (would add subprocess fan-out + flake).

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.history.configure(.{
        .path = "/tmp/atty-e2e-ghost-history",
        .format = .plain,
        .capacity = 32,
    }),
};
