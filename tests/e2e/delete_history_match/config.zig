//! delete_history_match — history pointed at a scenario-private file
//! so the scenario can record + delete without disturbing the user's
//! actual history. No statusbar: keeps the snapshot grid focused on
//! the ghost-on-prefix difference (deletion's primary observable).

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.history.configure(.{
        .path = "/tmp/atty-e2e-delete-history",
        .format = .plain,
        .capacity = 32,
    }),
};
