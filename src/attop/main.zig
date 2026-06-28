//! attop — the atty dashboard (docs/dashboard.md).
//!
//! A standalone TUI (the "Grafana" of atty) that reads the atty-guard
//! metrics API and answers, at a glance: am I protected, what is atty
//! doing for me, is everything healthy. It is NOT part of the hot-path
//! proxy — it reuses the `atty` module's style/ansi primitives but runs as
//! its own binary, talking to the daemon over the UDS.
//!
//! This is the P2 SKELETON: it wires the binary + the atty-module reuse and
//! detects the atty session. The live TUI — the terminal render loop, the
//! `get_metrics` UDS client, and the Home screen — lands in the next P2
//! step (docs/dashboard.md "Phasing": P2 = skeleton + Home).

const std = @import("std");
const atty = @import("atty");

// Force-analyze the atty-module reuse so the cross-binary import wiring
// compiles (the live render core consumes atty.ansi / atty.style next).
comptime {
    _ = atty.Style;
    _ = atty.ansi;
}

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;

pub fn main() void {
    var buf: [160]u8 = undefined;
    const line = banner(&buf, getenv("ATTY") != null);
    _ = write(1, line.ptr, line.len);
}

/// The startup line. Pure (no I/O) so it's unit-testable without a TTY.
/// attop is atty-session-aware — it notes when launched beneath atty; the
/// embedded `doctor` health-check + the current-session highlight in Fleet
/// build on this detection later.
fn banner(buf: []u8, under_atty: bool) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "attop — atty dashboard (WIP){s}\n" ++
            "The live TUI lands in the next build; see docs/dashboard.md.\n",
        .{if (under_atty) " · in atty session" else ""},
    ) catch "attop — atty dashboard (WIP)\n";
}

test "banner notes the atty session + stays bounded" {
    var buf: [160]u8 = undefined;
    const in_session = banner(&buf, true);
    try std.testing.expect(std.mem.indexOf(u8, in_session, "in atty session") != null);
    try std.testing.expect(std.mem.indexOf(u8, in_session, "attop") != null);

    const standalone = banner(&buf, false);
    try std.testing.expect(std.mem.indexOf(u8, standalone, "in atty session") == null);
    try std.testing.expect(std.mem.indexOf(u8, standalone, "attop") != null);
}
