//! ghost_pick — pick-list with N=3 + scenario-private history file
//! so the recorded entries are deterministic.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.history.configure(.{
        .path = "/tmp/atty-e2e-ghost-pick",
        .format = .plain,
        .capacity = 32,
    }),
};

pub const ghost: atty.Ghost = .{
    .list_count = 3,
    .list_render = .inline_rows,
};
