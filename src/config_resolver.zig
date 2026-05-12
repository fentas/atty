//! Merges the user's `src/config.zig` with the shipped defaults.
//!
//! Every internal consumer (`proxy.zig`, `dispatch.zig`) imports
//! atty's `config` module — that's this file. For each knob, the
//! user's declaration wins via `@hasDecl`; otherwise we fall through
//! to `defaults.zig`. New tunables added upstream don't break user
//! configs because the user simply doesn't declare them and the
//! default value flows through.
//!
//! When adding a new knob: declare it in `defaults.zig`, mirror the
//! resolver entry below, and optionally show it as a commented
//! example in `src/config.zig`.

const user = @import("user_config");
const defaults = @import("defaults.zig");

pub const modules = if (@hasDecl(user, "modules"))
    user.modules
else
    defaults.modules;

pub const tick_interval_ms = if (@hasDecl(user, "tick_interval_ms"))
    user.tick_interval_ms
else
    defaults.tick_interval_ms;

pub const ghost_style = if (@hasDecl(user, "ghost_style"))
    user.ghost_style
else
    defaults.ghost_style;

pub const bindings = if (@hasDecl(user, "bindings"))
    user.bindings
else
    defaults.bindings;
