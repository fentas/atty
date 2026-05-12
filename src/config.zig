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

/// Key bindings — dwm-style `keys[]` array. Each entry is a
/// `{ bytes, action }` pair: when stdin reads exactly `bytes`, the
/// `action` runs instead of the keystroke flowing through to the
/// shell.
///
/// Common byte sequences:
///
///   "\x1b[C"     right-arrow
///   "\x1b[F"     End
///   "\x1bOC"     right-arrow       (terminals in application-cursor mode)
///   "\x1b[1;5C"  Ctrl-Right-arrow  (xterm-style)
///   "\x1b[Z"     Shift-Tab
///   "\x06"       Ctrl-F            (Emacs-style end-of-line)
///   "\t"         Tab               (warning: clobbers shell completion)
///
/// Note: Ctrl-Tab is not a standard terminal sequence — most terminals
/// don't emit anything distinct for it. Use Ctrl-F or right-arrow.
pub const bindings: []const atty.keymap.Binding = &.{
    .{ .bytes = "\x1b[C", .action = .ghost_accept }, // right-arrow (fish, zsh-autosuggestions)
    .{ .bytes = "\x1b[F", .action = .ghost_accept }, // End
    .{ .bytes = "\x06", .action = .ghost_accept }, // Ctrl-F
};
