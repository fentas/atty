//! ghost_list_clear_on_enter — pick-list enabled + a scenario-private
//! history file. Verifies the list is cleared on Enter BEFORE the shell
//! writes its (shorter) command output onto the list's rows, so no list
//! row tail survives as residue.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.history.configure(.{
        .path = "/tmp/atty-e2e-ghost-list-clear",
        .format = .plain,
        .capacity = 32,
    }),
};

pub const ghost: atty.Ghost = .{
    .list_count = 3,
};
