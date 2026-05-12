//! incognito_toggle — atty built with the status bar enabled so the
//! 🔒 segment is observable when the user toggles incognito on via
//! Ctrl+Shift+I (kitty-keyboard CSI-u, with the protocol push that
//! ships by default).

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
};

pub const statusbar: atty.StatusBar = .{
    .enabled = true,
    .base_text = "atty",
};
