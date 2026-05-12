//! atty configuration — the Suckless config.h equivalent.
//!
//! Edit this file. Recompile. That is the entire configuration model.
//!
//! Every knob has a sensible default in `src/defaults.zig`. Declare
//! only the ones you want to override — new defaults added upstream
//! flow through automatically, so `git pull` rarely conflicts here.
//!
//! Track your config outside the repo with
//! `-Dconfig=/path/to/mine.zig` (or `make CONFIG=/path/to/mine.zig build`).

const atty = @import("atty");

// ───── Modules ──────────────────────────────────────────────────────────
//
// Order = priority. Short-circuiting modules first (Guardrail). The
// default tuple is `{ guardrail, atuin }` with each module's
// `configure(.{})` defaults. Uncomment + edit to override.
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
//     }),
//     atty.modules.history.configure(.{}),  // shell-native fallback
// };

// ───── Proxy tunables ───────────────────────────────────────────────────
//
// pub const tick_interval_ms: i32 = 50;

// ───── Visual style ─────────────────────────────────────────────────────
//
// `atty.Style` is the shared styling primitive (ghost overlay,
// guardrail warning, …). Presets in `atty.style.presets`, or write
// literals: `.{ .dim = true, .italic = true, .fg = 244 }`.
//
// pub const ghost_style: atty.Style = atty.style.presets.muted_italic;
// pub const ghost_style: atty.Style = .{ .fg = 244 };  // mid-gray

// ───── Key bindings ─────────────────────────────────────────────────────
//
// Defaults bind Right / End / Ctrl+F → ghost_accept. Override the
// whole array to change them. `atty.keymap.key("…")` resolves at
// compile time, so typos error the build. See src/keymap.zig for
// supported names (Ctrl+Shift+Right, Alt+f, F1–F12, …).
//
// pub const bindings: []const atty.keymap.Binding = &.{
//     .{ .bytes = atty.keymap.key("Ctrl+F"), .action = .ghost_accept },
//     .{ .bytes = atty.keymap.key("End"),    .action = .ghost_accept },
// };
