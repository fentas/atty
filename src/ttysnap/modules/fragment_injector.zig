//! fragment_injector — fault injection: cap each master read to N bytes so the
//! child's output, and the escape sequences inside it, split across reads on
//! demand.
//!
//! This turns load-dependent fragmentation races — the kind atty's #525 ghost
//! flake hit only under CI load — into DETERMINISTIC, reproducible behaviour. A
//! browser test framework has no analog; it's the payoff of fault injection
//! being a composable module rather than a global switch.
//!
//! Compose: `fragment_injector(.{ .bytes = 16 })` in the `modules` tuple. It
//! composes with other `beforeRead` modules — the ttysnap applies the smallest
//! cap any of them requests.

const std = @import("std");
const mod = @import("../module.zig");

pub fn fragment_injector(comptime cfg: struct {
    /// Max bytes per master read. 0 = no cap (the module becomes inert).
    bytes: usize,
}) type {
    return struct {
        pub const Runtime = struct {};

        pub fn attach(_: std.mem.Allocator, _: mod.SessionInfo) !Runtime {
            return .{};
        }

        pub fn beforeRead(_: *Runtime, want: usize) usize {
            return if (cfg.bytes > 0 and cfg.bytes < want) cfg.bytes else want;
        }
    };
}
