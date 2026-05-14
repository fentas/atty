//! ghost_starship_overwrite — exercise the case where a prompt
//! manager (Starship, oh-my-posh, custom) overwrites `PS1` from
//! INSIDE PROMPT_COMMAND on every cycle. The shipped one-shot
//! `PS1=$'…;A…\$PS1…;B…'` at init time got blown away on the very
//! first redraw, so users with Starship lost OSC 133 markers and
//! atty's `inSubprocess` gate suspended ghost text + history
//! recording at the local prompt.
//!
//! Fix: `__atty_osc133_wrap_ps1` is now in PROMPT_COMMAND too,
//! ordered AFTER the user's existing entries. It re-applies the
//! `;A` / `;B` wrap on each cycle and is idempotent so it's a
//! no-op when nothing overwrote PS1.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.history.configure(.{
        .path = "/tmp/atty-e2e-ghost-starship-overwrite",
        .format = .plain,
        .capacity = 32,
    }),
};
