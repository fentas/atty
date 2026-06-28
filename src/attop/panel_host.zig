//! PanelHost(panels) — attop's comptime panel walker.
//!
//! The dashboard sibling of the proxy's `Dispatcher(modules)`
//! (src/dispatch.zig): given a comptime tuple of panel *types*, produce
//! a `Runtimes` tuple (one `*Runtime` per panel) + walkers that fan a
//! hook into the right panel. Every hook lookup is `@hasDecl` at
//! comptime, so a panel contributes zero code for hooks it omits and
//! deleting a panel from the tuple removes it from the binary entirely.
//!
//! Unlike the proxy (which fans most hooks into ALL modules), the
//! dashboard has exactly one FOCUSED panel at a time, so render/onKey
//! target a single index; onTick fans into all (panels may keep state
//! warm off-screen).

const std = @import("std");
const panel = @import("panel.zig");

const Ctx = panel.Ctx;
const Action = panel.Action;
const Key = panel.Key;

pub fn PanelHost(comptime panels: anytype) type {
    const N = panels.len;

    return struct {
        pub const count = N;

        /// Heterogeneous tuple of pointers to each panel's runtime — same
        /// rationale as Dispatcher.Runtimes (stable heap addresses; no
        /// comptime-var-pointer-at-runtime).
        pub const Runtimes = blk: {
            var types: [N]type = undefined;
            for (panels, 0..) |P, i| types[i] = *P.Runtime;
            break :blk std.meta.Tuple(&types);
        };

        pub fn attachAll(allocator: std.mem.Allocator) !Runtimes {
            var rts: Runtimes = undefined;
            var attached: usize = 0;
            errdefer detachUpTo(allocator, &rts, attached);
            inline for (panels, 0..) |P, i| {
                const slot = try allocator.create(P.Runtime);
                slot.* = P.attach(allocator) catch |err| {
                    allocator.destroy(slot);
                    return err;
                };
                rts[i] = slot;
                attached = i + 1;
            }
            return rts;
        }

        pub fn detachAll(allocator: std.mem.Allocator, rts: *Runtimes) void {
            detachUpTo(allocator, rts, N);
        }

        fn detachUpTo(allocator: std.mem.Allocator, rts: *Runtimes, n: usize) void {
            inline for (panels, 0..) |P, i| {
                if (i < n) {
                    if (comptime @hasDecl(P, "detach")) P.detach(rts[i]);
                    allocator.destroy(rts[i]);
                }
            }
        }

        // ---- per-frame, focused-panel hooks --------------------------------

        /// Render the panel at `idx` into `w`.
        pub fn renderAt(rts: *Runtimes, ctx: *Ctx, idx: usize, w: *std.Io.Writer) !void {
            inline for (panels, 0..) |P, i| {
                if (i == idx) return P.render(rts[i], ctx, w);
            }
        }

        /// Route a key to the panel at `idx`. Panels without `onKey`
        /// return `.pass` so the host applies global handling.
        pub fn keyAt(rts: *Runtimes, ctx: *Ctx, idx: usize, k: Key) !Action {
            inline for (panels, 0..) |P, i| {
                if (i == idx) {
                    if (comptime @hasDecl(P, "onKey")) return P.onKey(rts[i], ctx, k);
                    return .pass;
                }
            }
            return .pass;
        }

        /// The panel at `idx`'s footer hint (panel-specific key legend),
        /// or null.
        pub fn footerHintAt(rts: *Runtimes, ctx: *Ctx, idx: usize) ?[]const u8 {
            inline for (panels, 0..) |P, i| {
                if (i == idx) {
                    if (comptime @hasDecl(P, "footerHint")) return P.footerHint(rts[i], ctx);
                    return null;
                }
            }
            return null;
        }

        // ---- all-panel hooks ----------------------------------------------

        pub fn tickAll(rts: *Runtimes, ctx: *Ctx, elapsed_ms: u64) !void {
            inline for (panels, 0..) |P, i| {
                if (comptime @hasDecl(P, "onTick")) try P.onTick(rts[i], ctx, elapsed_ms);
            }
        }

        // ---- comptime metadata --------------------------------------------

        pub fn titleAt(idx: usize) []const u8 {
            inline for (panels, 0..) |P, i| {
                if (i == idx) return P.title();
            }
            return "";
        }

        pub fn navKeyAt(idx: usize) u8 {
            inline for (panels, 0..) |P, i| {
                if (i == idx) return P.navKey();
            }
            return 0;
        }

        /// Map a global nav hotkey (e.g. 'g') to its panel index, or null.
        pub fn indexForKey(k: u8) ?usize {
            inline for (panels, 0..) |P, i| {
                if (P.navKey() == k) return i;
            }
            return null;
        }

        /// Landing panel: the first panel that votes `wantsFocusAtStart`,
        /// else panel 0. Lets Setup grab focus when the stack isn't ready
        /// without the host hard-coding which panel that is.
        pub fn landingIndex(ctx: *Ctx) usize {
            inline for (panels, 0..) |P, i| {
                if (comptime @hasDecl(P, "wantsFocusAtStart")) {
                    if (P.wantsFocusAtStart(ctx)) return i;
                }
            }
            return 0;
        }
    };
}

test {
    _ = @import("panel_host_tests.zig");
}
