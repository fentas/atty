//! resize_injector — fault injection: drive SIGWINCH storms by resizing the
//! child's terminal (TIOCSWINSZ on the master) on a cadence, surfacing resize
//! races and broken redraw-on-resize handling.
//!
//! It cycles through `sizes`, applying the next one on every Nth output chunk.
//! NOTE: a module only gets the master fd, not ttysnap's grid, so this resizes
//! the CHILD's terminal (the SIGWINCH stressor — "does the TUI survive a resize
//! storm") but leaves the observer grid at the spawn size. To resize the grid
//! too (and assert the post-resize screen), call `Harness.resize` from the
//! scenario instead.
//!
//! Compose: `resize_injector(.{ .every = 4, .sizes = &.{ .{ .cols = 120, .rows = 40 }, .{ .cols = 80, .rows = 24 } } })`.

const std = @import("std");
const mod = @import("../module.zig");
const pty = @import("pty");

pub const Size = struct { cols: u16, rows: u16 };

pub fn resize_injector(comptime cfg: struct {
    /// Apply the next size on every Nth output chunk (clamped to >= 1).
    every: usize = 1,
    /// Sizes to cycle through, one applied per trigger. Empty = inert.
    sizes: []const Size,
}) type {
    return struct {
        pub const Runtime = struct {
            master: std.posix.fd_t,
            chunk: usize = 0,
            next: usize = 0,
        };

        pub fn attach(_: std.mem.Allocator, info: mod.SessionInfo) !Runtime {
            return .{ .master = info.master };
        }

        pub fn onOutput(rt: *Runtime, _: []const u8) void {
            if (shouldResize(rt)) |s| _ = pty.setSize(rt.master, s.cols, s.rows);
        }

        /// Advance the chunk counter and, on a trigger chunk, return the next
        /// size to apply (cycling `sizes`). NOT a lifecycle hook — it's `pub`
        /// only so the cadence is unit-testable without a live PTY; `onOutput`
        /// is the real driver.
        pub fn shouldResize(rt: *Runtime) ?Size {
            if (cfg.sizes.len == 0) return null;
            rt.chunk += 1;
            if (rt.chunk % @max(cfg.every, 1) != 0) return null;
            const s = cfg.sizes[rt.next % cfg.sizes.len];
            rt.next += 1;
            return s;
        }
    };
}

test {
    _ = @import("resize_injector_tests.zig");
}
