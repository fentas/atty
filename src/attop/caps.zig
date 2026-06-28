//! attop runtime capability detection — what the dashboard can see about the
//! host (attop is a separate binary talking to the daemon over the UDS, so
//! this is system state, not atty's compiled config). Drives the wizard
//! landing + capability-gated screens: don't show what isn't there, guide
//! the user to install/enable it instead.

const std = @import("std");

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
const X_OK: c_int = 1;

/// Is the `atty` binary installed + executable on $PATH? (The wizard guides
/// installation when not.)
pub fn attyOnPath() bool {
    const path = std.c.getenv("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, std.mem.span(path), ':');
    var buf: [4096]u8 = undefined;
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        // "<dir>/atty\0"; skip a dir whose path won't fit the buffer.
        const candidate = std.fmt.bufPrintZ(&buf, "{s}/atty", .{dir}) catch continue;
        if (access(candidate.ptr, X_OK) == 0) return true;
    }
    return false;
}

/// Running inside an atty session? (atty exports $ATTY into the child shell.)
pub fn underAtty() bool {
    return std.c.getenv("ATTY") != null;
}

test {
    _ = @import("caps_tests.zig");
}
