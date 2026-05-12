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
    .suggestion_ttl_ms = 0, // 0 = no idle timer (fish-style); set ms to fade
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

/// Visual style for the ghost-text overlay (the dim suggestion after
/// the cursor). Default matches fish + zsh-autosuggestions: dim, no
/// italic, terminal's default colour. Set `.fg` to a 256-colour index
/// for a specific shade — 244 is a comfortable mid-gray.
pub const ghost_style: atty.ghost.Style = .{
    .dim = true,
    .italic = false,
    // .fg = 244,
};

/// Key bindings — dwm-style `keys[]` array. Each entry is a
/// `{ bytes, action }` pair: when stdin reads exactly `bytes`, the
/// `action` runs instead of the keystroke flowing through to the
/// shell.
///
/// Use `atty.keymap.key("Right")` rather than raw byte sequences —
/// the helper resolves at compile time, so typos error the build.
/// Supported names: arrows + nav (`Right`/`Left`/`Up`/`Down`/`Home`/
/// `End`/`PageUp`/`PageDown`/`Insert`/`Delete`), `Tab`/`Enter`/
/// `Backspace`/`Esc`, xterm CSI-1 modifier combos (`Ctrl+Right`,
/// `Shift+End`, `Ctrl+Shift+Up`, `Ctrl+Alt+Left`, …), `Ctrl+<letter>`,
/// `Alt+<char>`, `F1`–`F12`. See src/keymap.zig.
///
/// Super/Win/Cmd has no portable terminal sequence; `Ctrl+Tab` etc.
/// is indistinguishable from `Tab` on most terminals. For exotic
/// sequences (kitty keyboard protocol) the `.bytes` field still
/// accepts raw byte literals.
pub const bindings: []const atty.keymap.Binding = &.{
    .{ .bytes = atty.keymap.key("Right"), .action = .ghost_accept }, // fish, zsh-autosuggestions
    .{ .bytes = atty.keymap.key("End"), .action = .ghost_accept },
    .{ .bytes = atty.keymap.key("Ctrl+F"), .action = .ghost_accept }, // Emacs end-of-line
};
