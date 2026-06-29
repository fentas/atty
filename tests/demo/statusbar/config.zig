//! atty_demo:statusbar — atty built with the headline modules + status bar for the
//! showcase GIF. NOT a regression test; the e2e runner builds atty against this
//! and records the cast that scripts/gen-demo-gifs.sh turns into a GIF.
const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.history.configure(.{ .path = "/tmp/atty-demo-statusbar" }),
};

pub const statusbar: atty.StatusBar = .{
    .enabled = true,
    .base_text = "atty",
};
