//! smoke_echo — pinned config so the snapshot is deterministic
//! regardless of what the user has in their src/config.zig.
//!
//! Just guardrail (no ghost/history side effects), statusbar off.

const atty = @import("atty");

pub const modules = .{
    atty.modules.guardrail.configure(.{}),
};
