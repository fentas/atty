//! ghost_first_char_dropped — repro the user-reported off-by-one
//! in ghost-text matching that surfaces under the array
//! PROMPT_COMMAND + starship-like prompt-manager combo.
//!
//! Bash-native history (no atuin daemon needed). The seeded
//! entries start with `e` so a correct match against typed `e`
//! shows them; if the first char is dropped, the match silently
//! fails (or matches whatever the SECOND char would prefix).

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.history.configure(.{}),
};

pub const statusbar: atty.StatusBar = .{
    .enabled = true,
    .base_text = "atty",
};
