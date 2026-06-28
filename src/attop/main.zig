//! attop — the atty dashboard.
//!
//! A standalone TUI (the "Grafana" of atty) that reads the atty-guard
//! metrics API and answers, at a glance: am I protected, what is atty
//! doing for me, is everything healthy. It is NOT part of the hot-path
//! proxy — it reuses the `atty` module's style/ansi primitives but runs as
//! its own binary, talking to the daemon over the UDS. See
//! docs/dashboard.md for the design.
//!
//! The terminal render loop, the metrics UDS client, and the screens are
//! not wired yet — `main` prints a status banner so the binary is real
//! while the render core is built.

const std = @import("std");
const atty = @import("atty");

// Force-analyze the atty-module reuse so the cross-binary import wiring
// compiles (the render core consumes atty.ansi / atty.style).
comptime {
    _ = atty.Style;
    _ = atty.ansi;
}

pub fn main() void {
    var buf: [160]u8 = undefined;
    const line = banner(&buf, std.c.getenv("ATTY") != null);
    _ = std.c.write(std.posix.STDOUT_FILENO, line.ptr, line.len);
}

/// The startup line. Pure (no I/O) so it's unit-testable without a TTY.
/// attop is session-aware — it notes when launched beneath atty; the
/// embedded doctor health-check + the Fleet current-session highlight
/// build on this detection.
pub fn banner(buf: []u8, under_atty: bool) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "attop — atty dashboard (WIP){s}\n" ++
            "The live TUI is not built yet; see docs/dashboard.md.\n",
        .{if (under_atty) " · in atty session" else ""},
    ) catch "attop — atty dashboard (WIP)\nThe live TUI is not built yet; see docs/dashboard.md.\n";
}

test {
    _ = @import("main_tests.zig");
}
