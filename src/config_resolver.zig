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
//! plus one resolver entry + type re-export here AND its name to
//! `known_config_decls` below — otherwise the unknown-decl guard will
//! reject the new (valid) override in a user's config.zig.

const std = @import("std");
const user = @import("user_config");
const defaults = @import("defaults.zig");

// Reject typo'd / stale top-level overrides in src/config.zig at compile
// time. Without this a `pub const statusbars = …` (or a renamed-away
// knob) compiles clean and the default silently wins — the exact
// "silent config typo" the keyed-config philosophy is meant to prevent.
// Only PUBLIC decls are inspected (Zig surfaces just those in typeInfo),
// so private helpers like `const atty = @import("atty")` are ignored.
const known_config_decls = [_][]const u8{
    "modules",   "proxy",      "ghost",
    "terminal",  "mouse",      "keymap",
    "statusbar", "subprocess",
};

comptime {
    for (@typeInfo(user).@"struct".decls) |decl| {
        var known = false;
        for (known_config_decls) |name| {
            if (std.mem.eql(u8, decl.name, name)) {
                known = true;
                break;
            }
        }
        if (!known) {
            @compileError("unknown declaration `" ++ decl.name ++
                "` in src/config.zig — typo or stale knob? " ++
                "Recognized overrides: modules, proxy, ghost, terminal, " ++
                "mouse, keymap, statusbar, subprocess. " ++
                "(Make private helpers non-`pub`.)");
        }
    }
}

// ───── Type re-exports ─────────────────────────────────────────────────
// Consumers annotate their overrides with these:
//   pub const ghost: atty.config.Ghost = .{ .style = ... };
pub const Proxy = defaults.Proxy;
pub const Ghost = defaults.Ghost;
pub const Terminal = defaults.Terminal;
pub const Mouse = defaults.Mouse;
pub const Keymap = defaults.Keymap;
pub const StatusBar = defaults.StatusBar;
pub const Subprocess = defaults.Subprocess;

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

pub const mouse = if (@hasDecl(user, "mouse"))
    user.mouse
else
    defaults.mouse;

pub const keymap = if (@hasDecl(user, "keymap"))
    user.keymap
else
    defaults.keymap;

pub const statusbar = if (@hasDecl(user, "statusbar"))
    user.statusbar
else
    defaults.statusbar;

pub const subprocess = if (@hasDecl(user, "subprocess"))
    user.subprocess
else
    defaults.subprocess;
