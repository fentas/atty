//! The attop Panel contract — attop's "module framework".
//!
//! Mirrors atty's `Module` framework (src/module.zig + src/dispatch.zig):
//! a panel is a TYPE with a `Runtime` (its state) plus a set of optional
//! hooks discovered via `@hasDecl`. `PanelHost(panels)` (panel_host.zig)
//! walks a comptime tuple of panel types the same way the proxy's
//! `Dispatcher(modules)` walks modules — no vtable, no `*anyopaque`, no
//! runtime branch on the panel list. Add a panel = add a struct to the
//! `panels` tuple in `config.zig` and recompile.
//!
//! Hook shape (each guarded by `@hasDecl`, so a panel only declares what
//! it uses):
//!
//!   pub const Runtime = struct { … }                 // per-panel state
//!   pub fn attach(allocator) !Runtime                 // required
//!   pub fn detach(rt: *Runtime) void                  // optional
//!   pub fn title() []const u8                          // required — tab label
//!   pub fn navKey() u8                                 // required — global hotkey
//!   pub fn render(rt, ctx, w: *std.Io.Writer) !void    // required
//!   pub fn onKey(rt, ctx, k: Key) !Action             // optional
//!   pub fn onClick(rt, ctx, col, row: u16) !Action     // optional — mouse
//!   pub fn onTick(rt, ctx, elapsed_ms: u64) !void      // optional
//!   pub fn footerHint(rt, ctx) ?[]const u8            // optional — panel keys
//!   pub fn wantsFocusAtStart(ctx) bool                // optional — landing vote

const std = @import("std");
const uds = @import("uds.zig");
const key = @import("key.zig");

pub const Key = key.Key;

/// Host capability snapshot. Lives here (not in setup.zig) so the
/// contract owns it and panels don't import each other.
pub const Host = struct {
    atty_on_path: bool = false,
    under_atty: bool = false,
    shell_integrated: bool = false,
    shell_name: []const u8 = "bash",
};

/// Per-frame, read-only snapshot handed to every panel hook. The host
/// fetches daemon data on the refresh tick and caches it here; keystrokes
/// re-render from the cache (instant — no UDS round-trip per key).
pub const Ctx = struct {
    /// Latest get_metrics reply, or null when the daemon is unreachable.
    metrics: ?uds.Metrics = null,
    /// Latest list_instances reply. null = the fetch failed (daemon
    /// unreachable); an empty slice = reachable but no live sessions —
    /// the Fleet panel renders those two states differently.
    instances: ?[]const uds.Instance = null,
    /// atty installed / under-atty / shell-wired — fixed for the session.
    host: Host = .{},
    cols: u16 = 80,
    rows: u16 = 24,
    /// 1-based screen row where THIS panel's content begins (just below the
    /// tab bar). A panel maps a mouse click's row to a list index with
    /// `content_row + own_header_height` — no hard-coded screen offsets, so
    /// the mapping survives tab-bar layout changes.
    content_row: u16 = 3,
    /// True when this panel currently has focus (drives selection paint).
    focused: bool = true,
    /// Per-frame scratch arena (freed after the frame). Panels write
    /// their UI into the writer passed to `render`, not here.
    arena: std.mem.Allocator,
};

/// A panel's reply to `onKey` — how the host should react.
pub const Action = union(enum) {
    /// Not handled; the host applies global handling (focus nav, quit).
    pass,
    /// Handled — the host re-renders from cached data.
    handled,
    /// Quit attop.
    quit,
    /// Re-fetch daemon data now (don't wait for the tick), then render.
    refresh,
};
