//! atty_demo:ghost — fish-style inline ghost-text AND the numbered pick-list
//! (Ctrl+1..9) of recent matches. NOT a regression test. list_count = 3 turns
//! on the pick-list; the scenario seeds several commands sharing a prefix.
const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.history.configure(.{ .path = "/tmp/atty-demo-ghost" }),
};

pub const ghost: atty.Ghost = .{ .list_count = 3 };

pub const statusbar: atty.StatusBar = .{
    .enabled = true,
    .base_text = "atty",
};
