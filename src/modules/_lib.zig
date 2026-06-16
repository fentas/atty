//! Shared helpers for built-in modules.
//!
//! Not exposed via the `atty` root — modules import this directly
//! via the sibling-file path `@import("_lib.zig")`. The leading
//! underscore signals "private to this directory; not part of the
//! public module API."
//!
//! Bar for adding something here: at least two module consumers, OR
//! a tricky-enough primitive that we'd rather have one tested copy
//! than two ad-hoc reimplementations. nowMs + ListBuilder qualify
//! on both counts.

const std = @import("std");

// ---------------------------------------------------------------------------
// Monotonic clock — used by atuin / history (and statusbar from outside
// the modules dir keeps its own copy until the next refactor sweep).
// ---------------------------------------------------------------------------

pub fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    // `.MONOTONIC` is the OS-correct clockid_t (Linux 1, Darwin 6, …).
    // Hardcoding the Linux value made `nowMs()` return 0 on Darwin,
    // silently breaking every module timer.
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), std.time.ns_per_ms);
}

// ---------------------------------------------------------------------------
// ListBuilder — fixed-cap ordered slice-of-slices with skip + dedup
// on insertion. The hot path for `provideGhostList` across modules
// looks identical: walk candidates newest-first, skip the entry the
// inline ghost is already showing, dedupe by content, cap at the
// max-pick-binding count.
//
// Example:
//     var builder = ListBuilder(9){};
//     while (it.next()) |c| if (!builder.tryAdd(c, inline_match)) {
//         if (builder.full()) break;
//     }
//     return builder.items();
//
// The returned slice borrows from the builder's own storage. Callers
// must keep the builder alive across the slice's use (typically a
// single dispatch call). The slices inside the builder are not
// copied — they borrow from the module's own storage in turn.
// ---------------------------------------------------------------------------

pub fn ListBuilder(comptime cap: usize) type {
    return struct {
        buf: [cap][]const u8 = undefined,
        len: usize = 0,

        pub fn tryAdd(self: *@This(), entry: []const u8, skip: ?[]const u8) bool {
            if (self.len >= cap) return false;
            if (entry.len == 0) return false;
            if (skip) |s| if (std.mem.eql(u8, entry, s)) return false;
            for (self.buf[0..self.len]) |existing| {
                if (std.mem.eql(u8, existing, entry)) return false;
            }
            self.buf[self.len] = entry;
            self.len += 1;
            return true;
        }

        pub fn items(self: *const @This()) []const []const u8 {
            return self.buf[0..self.len];
        }

        pub fn full(self: *const @This()) bool {
            return self.len >= cap;
        }

        pub fn reset(self: *@This()) void {
            self.len = 0;
        }
    };
}

// ===========================================================================
// Tests — extracted to `_lib_tests.zig` for readability.
// ===========================================================================

test {
    _ = @import("_lib_tests.zig");
}
