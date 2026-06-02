//! ghost_midline_then_right_then_delete — typing-from-scratch flavour
//! of the mid-line ghost overpaint bug. Distinct from
//! ghost_midline_insert_after_uparrow (which exercises Arrow-Up history
//! recall): here the user types the command verbatim, navigates back
//! into the middle, inserts a space, returns to EOL, and backspaces.
//! No ghost should engage on the resulting two-space variant.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.history.configure(.{
        .path = "/tmp/atty-e2e-ghost-midline-right",
        .format = .plain,
        .capacity = 32,
    }),
};
