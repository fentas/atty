//! atty — library entry point.
//!
//! Re-exports the public API so external code (tests, user configs)
//! can `@import("atty")` and pull everything from one place.

pub const version = @import("version.zig").version;

pub const module = @import("module.zig");
pub const dispatch = @import("dispatch.zig");
pub const line_state = @import("line_state.zig");
pub const ansi = @import("ansi.zig");
pub const ghost = @import("ghost.zig");
pub const pty = @import("pty.zig");
pub const terminal = @import("terminal.zig");
pub const proxy = @import("proxy.zig");
pub const keymap = @import("keymap.zig");
pub const style = @import("style.zig");
pub const Style = style.Style;

/// Built-in modules. User configs compose these via
/// `atty.modules.atuin.configure(.{...})`.
pub const modules = struct {
    pub const atuin = @import("modules/atuin.zig");
    pub const guardrail = @import("modules/guardrail.zig");
    pub const history = @import("modules/history.zig");
};

// Pull every test in the project into the runner.
test {
    @import("std").testing.refAllDeclsRecursive(@This());
}
