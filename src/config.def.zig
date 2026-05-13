//! atty configuration — the Suckless config.h equivalent.
//!
//! Edit this file. Recompile. That is the entire configuration model.
//!
//! Every subsystem is a struct with per-field defaults in
//! `src/defaults.zig`. Declare only the fields you want to override —
//! the rest fall through to the type's defaults, and new fields added
//! upstream flow in automatically. `git pull` rarely conflicts here.
//!
//! Track your config outside the repo with
//! `-Dconfig=/path/to/mine.zig` (or `make CONFIG=/path/to/mine.zig build`).

const atty = @import("atty");

// ───── Modules ──────────────────────────────────────────────────────────
//
// Order = priority. Short-circuiting modules first (Guardrail). The
// default tuple is dependency-free: { guardrail, history }. The
// history module reads/writes your shell's own ~/.bash_history /
// ~/.zsh_history — no `atuin` binary required.
//
// Want atuin instead of (or alongside) history? Uncomment and edit:
//
// pub const modules = .{
//     atty.modules.guardrail.configure(.{
//         // .rules = &.{ ... },
//         // .warning_style = atty.style.presets.danger,
//     }),
//     atty.modules.atuin.configure(.{
//         // .suggestion_ttl_ms = 0,        // 0 = fish-style, no fadeout
//         // .sync_after_records = 10,
//         // .sync_interval_ms = 60_000,
//         // .delete_scope = .exact,       // .exact / .prefix /
//         //                                // .full_text / .fuzzy —
//         //                                // controls Ctrl+Shift+D's
//         //                                // reach into atuin. Default
//         //                                // .exact uses atuin fuzzy +
//         //                                // `^line$` anchors so only
//         //                                // the typed line is removed.
//     }),
//     atty.modules.history.configure(.{}),  // optional fallback after atuin
// };

// ───── Proxy ────────────────────────────────────────────────────────────
//
// pub const proxy: atty.Proxy = .{
//     .tick_interval_ms = 50,                // default 100
// };

// ───── Ghost overlay ────────────────────────────────────────────────────
//
// `atty.Style` is the shared styling primitive (ghost overlay,
// statusbar segments, guardrail warning, …). Presets in
// `atty.style.presets`, or write literals:
// `.{ .dim = true, .italic = true, .fg = 244 }`.
//
// pub const ghost: atty.Ghost = .{
//     .style = atty.style.presets.muted_italic,
//     // Multi-row pick list below the prompt. 0 disables (default);
//     // 3 shows the next three matches after the inline ghost.
//     // Bound to Ctrl+1..Ctrl+9 (kitty kbd) and Esc+1..Esc+9 (legacy).
//     // .list_count = 3,
//     // .list_render = .inline_rows,  // .inline_rows / .reserved_region
//     // .list_style = atty.style.presets.muted,
// };

// ───── Terminal protocol ────────────────────────────────────────────────
//
// Off by default. See defaults.zig — opt in only if you know what you
// want from the kitty keyboard protocol; some binding combinations
// (Ctrl+Shift+I) need it but it can break Ctrl+D/Ctrl+C in the shell
// until atty grows a CSI-u → legacy translator.
//
// pub const terminal: atty.Terminal = .{ .enable_kitty_keyboard = true };

// ───── Key bindings ─────────────────────────────────────────────────────
//
// Defaults: Right / End / Ctrl+F → ghost_accept, Alt+i → incognito_toggle.
// `atty.keymap.key("…")` resolves at compile time — typos error the
// build. See src/keymap.zig for supported names (Ctrl+Shift+Right,
// Alt+f, F1–F12, …).
//
// pub const keymap: atty.Keymap = .{
//     .bindings = &.{
//         .{ .bytes = atty.keymap.key("Ctrl+F"), .action = .ghost_accept },
//         .{ .bytes = atty.keymap.key("Alt+i"),  .action = .incognito_toggle },
//     },
// };

// ───── Bottom status bar ────────────────────────────────────────────────
//
// Reserves rows at the bottom of the terminal via DECSTBM. Modules can
// contribute segments via the optional `statusText` hook (joined with
// " │ "). Off by default — opt in if you want it.
//
// pub const statusbar: atty.StatusBar = .{
//     .enabled = true,
//     .reserve_rows = 2,                              // text row + 1 blank above
//     .style = atty.style.presets.muted,
//     .base_text = "atty",                            // proxy-level prefix
//     .incognito_style = .{ .dim = true, .fg = 1 },   // muted red 🔒 segment
// };
