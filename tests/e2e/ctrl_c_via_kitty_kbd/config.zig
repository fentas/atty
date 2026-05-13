//! ctrl_c_via_kitty_kbd — same proxy build as the production binary
//! (kitty kbd enabled by default). The scenario sends the CSI-u form
//! of Ctrl+C and verifies atty translates it to \x03 before the byte
//! reaches the shell.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
};
