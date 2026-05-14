//! ghost_atty_init_bash — exercise the EXACT OSC 133 shape the
//! shipped `atty init bash` snippet sets up in the user's `.bashrc`:
//!
//!   - `;A` prepended to PS1 (prompt start)
//!   - `;B` appended  to PS1 (input-region open)
//!   - `;D` via PROMPT_COMMAND  (command finished + exit code)
//!   - NO `;C` (no preexec hook in bash)
//!
//! Differs from `ghost_partial_osc133` (`;A` only) and is the shape
//! a real Ghostty user with `eval "$(atty init bash)"` will hit.
//! If ghost text + history recording work here, the user's complaint
//! "still not working after rebuild" points at session staleness
//! (running an old atty under the existing terminal) or external
//! interference (atuin's own bash-preexec wiring mutating PROMPT_
//! COMMAND), not the proxy itself.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.history.configure(.{
        .path = "/tmp/atty-e2e-ghost-atty-init-bash",
        .format = .plain,
        .capacity = 32,
    }),
};
