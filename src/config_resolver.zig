//! Merges the user's `src/config.zig` with the shipped defaults.
//!
//! Every internal consumer (`proxy.zig`, `dispatch.zig`) imports
//! atty's `config` module — that's this file. For each knob, the
//! user's declaration wins via `@hasDecl`; otherwise we fall through
//! to `defaults.zig`. New tunables added upstream don't break user
//! configs because the user simply doesn't declare them and the
//! default value flows through (per-field via struct defaults inside
//! grouped subsystems, or whole-knob via this resolver).
//!
//! When adding a new knob: add a field to the relevant struct in
//! `defaults.zig`. Existing user configs pick it up via Zig's
//! per-field struct defaults — no resolver change needed. When adding
//! a whole new subsystem, add a struct + instance to `defaults.zig`
//! plus one resolver entry + type re-export here.

const user = @import("user_config");
const defaults = @import("defaults.zig");

// ───── Type re-exports ─────────────────────────────────────────────────
// Consumers annotate their overrides with these:
//   pub const ghost: atty.config.Ghost = .{ .style = ... };
pub const Proxy = defaults.Proxy;
pub const Ghost = defaults.Ghost;
pub const Terminal = defaults.Terminal;
pub const Keymap = defaults.Keymap;
pub const StatusBar = defaults.StatusBar;

// ───── Resolved values ─────────────────────────────────────────────────
pub const modules = if (@hasDecl(user, "modules"))
    user.modules
else
    defaults.modules;

pub const proxy = if (@hasDecl(user, "proxy"))
    user.proxy
else
    defaults.proxy;

pub const ghost = if (@hasDecl(user, "ghost"))
    user.ghost
else
    defaults.ghost;

pub const terminal = if (@hasDecl(user, "terminal"))
    user.terminal
else
    defaults.terminal;

pub const keymap = if (@hasDecl(user, "keymap"))
    user.keymap
else
    defaults.keymap;

pub const statusbar = if (@hasDecl(user, "statusbar"))
    user.statusbar
else
    defaults.statusbar;
