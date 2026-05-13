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
pub const ghost_list = @import("ghost_list.zig");
pub const osc133 = @import("osc133.zig");
pub const osc7 = @import("osc7.zig");
pub const altscreen = @import("altscreen.zig");
pub const subprocess = @import("subprocess.zig");
pub const pty = @import("pty.zig");
pub const terminal = @import("terminal.zig");
pub const proxy = @import("proxy.zig");
pub const keymap = @import("keymap.zig");
pub const style = @import("style.zig");
pub const Style = style.Style;
pub const statusbar = @import("statusbar.zig");
pub const status_text = @import("status_text.zig");
pub const args = @import("args.zig");

/// Config types — every subsystem is a struct, so user overrides
/// annotate with these and only spell out the fields they care
/// about. Per-field struct defaults fill the rest.
const config = @import("config");
pub const Proxy = config.Proxy;
pub const Ghost = config.Ghost;
pub const Terminal = config.Terminal;
pub const Keymap = config.Keymap;
pub const StatusBar = config.StatusBar;
pub const Subprocess = config.Subprocess;

/// Built-in modules. User configs compose these via
/// `atty.modules.atuin.configure(.{...})`.
pub const modules = struct {
    pub const atuin = @import("modules/atuin.zig");
    pub const guardrail = @import("modules/guardrail.zig");
    pub const history = @import("modules/history.zig");
    pub const llm = @import("modules/llm.zig");
};

// Pull every test in the project into the runner.
test {
    @import("std").testing.refAllDeclsRecursive(@This());
}
