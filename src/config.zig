//! atty configuration — the Suckless config.h equivalent.
//!
//! Edit this file. Recompile. That's the entire configuration model.
//!
//! Everything in this file is `comptime`. Disabling a module by
//! removing it from the `modules` tuple eliminates every byte of that
//! module's code from the resulting binary — no runtime flag, no
//! plugin loader, no stub.
//!
//! To use a config that lives outside the repo (e.g. tracked in your
//! dotfiles), pass `-Dconfig=/path/to/mine.zig` to `zig build`. Your
//! file should `@import("atty")` to reach the built-in modules.

const atty = @import("atty");

// ---------------------------------------------------------------------------
// Module instances — each `configure(...)` call returns a *type* with
// the given comptime config baked in. The proxy's dispatch loop walks
// these via `inline for`; missing hooks are statically dropped.
// ---------------------------------------------------------------------------

pub const Guardrail = atty.modules.guardrail.configure(.{
    // .rules = &.{
    //     .{ .name = "no-force-push", .kind = .{ .substring = "git push --force" }, .reason = "force push" },
    // },
});

pub const Atuin = atty.modules.atuin.configure(.{
    .backend = .subprocess,
    .search_mode = .prefix,
    .filter_mode = .global,
    .suggestion_ttl_ms = 5_000,
});

// ---------------------------------------------------------------------------
// The active module set. Order matters:
//
//   • Short-circuiting modules (Guardrail) go first — they should be
//     able to swallow an event before passive modules see it.
//
//   • Ghost-text providers are walked in order; first non-null wins.
//     Put your preferred history backend first.
// ---------------------------------------------------------------------------

pub const modules = .{
    Guardrail,
    Atuin,
};

// ---------------------------------------------------------------------------
// Tunables
// ---------------------------------------------------------------------------

/// poll() timeout — drives onTick cadence. Lower = more responsive
/// ghost-text expiry; higher = lower idle CPU.
pub const tick_interval_ms: i32 = 100;

/// Keystroke that accepts the current ghost suggestion (fish-style).
/// The bytes are checked against the entire stdin read — so this works
/// best with sequences a terminal emits as a single unit. Set to an
/// empty string to disable.
///
///   "\x1b[C"  right-arrow (default — matches fish, zsh-autosuggestions)
///   "\x1b[F"  End
///   "\x06"    Ctrl-F (Emacs-style end-of-line)
pub const accept_ghost_key: []const u8 = "\x1b[C";
