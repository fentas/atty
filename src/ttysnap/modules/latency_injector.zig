//! latency_injector — fault injection: sleep before each master read to slow the
//! pump, surfacing timing races a fast local run would hide. The time-domain
//! sibling of fragment_injector: that splits reads in space, this spreads them
//! in time, so a program that races output against a too-eager reader misbehaves
//! deterministically.
//!
//! Compose: `latency_injector(.{ .read_ms = 5 })` — sleep 5ms before each read.
//! Composes with other `beforeRead` modules (it returns `want` unchanged, so it
//! never caps; it only delays).

const std = @import("std");
const mod = @import("../module.zig");

pub fn latency_injector(comptime cfg: struct {
    /// Milliseconds to sleep before each master read. 0 = inert.
    read_ms: u64,
}) type {
    return struct {
        pub const Runtime = struct {};

        pub fn attach(_: std.mem.Allocator, _: mod.SessionInfo) !Runtime {
            return .{};
        }

        pub fn beforeRead(_: *Runtime, want: usize) usize {
            if (cfg.read_ms > 0) {
                const s = split(cfg.read_ms);
                std.posix.nanosleep(s.sec, s.nsec);
            }
            return want; // delay only — never cap
        }
    };
}

/// Split milliseconds into the (seconds, nanoseconds) `nanosleep` wants. Pure +
/// file-level so the conversion is unit-testable without sleeping.
pub fn split(ms: u64) struct { sec: u64, nsec: u64 } {
    return .{ .sec = ms / 1000, .nsec = (ms % 1000) * std.time.ns_per_ms };
}

test {
    _ = @import("latency_injector_tests.zig");
}
