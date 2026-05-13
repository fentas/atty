//! ctrl_c_aborts_line — default-modules-only build so the test
//! captures the proxy's behavior with the keymap and dispatchers
//! the shipped binary uses. No statusbar — keeps the snapshot
//! deterministic on the typed-line rows.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
};
