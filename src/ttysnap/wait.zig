//! Generic poll-until-condition + grid-query helpers shared by ttysnap's
//! `Harness` and the e2e `Session`. Both drive a PTY into a `vt.Grid` but pump
//! differently (the Harness fans reads to modules; the Session records a cast),
//! so `pumpMs` stays per-driver — these condition loops are identical and live
//! here once. Generic over any `driver` exposing `gridText() []const u8`,
//! `pumpMs(i32) !bool`, and an `exited: bool` field.

const std = @import("std");

/// Monotonic milliseconds (the proxy/statusbar clock idiom; immune to
/// wall-clock adjustments mid-run).
pub fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), std.time.ns_per_ms);
}

/// True if `needle` is anywhere on the current rendered screen.
pub fn gridContains(driver: anytype, needle: []const u8) bool {
    return std.mem.indexOf(u8, driver.gridText(), needle) != null;
}

/// Non-overlapping count of `needle` on the current rendered screen.
pub fn gridCount(driver: anytype, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    const text = driver.gridText();
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, needle)) |pos| {
        n += 1;
        i = pos + needle.len;
    }
    return n;
}

/// Pump until `needle` appears on screen or `timeout_ms` elapses. Drains once
/// more if the child exits with the needle still absent, so output racing the
/// exit is still seen.
pub fn waitFor(driver: anytype, needle: []const u8, timeout_ms: u32) !bool {
    const deadline = nowMs() + @as(i64, timeout_ms);
    while (true) {
        if (gridContains(driver, needle)) return true;
        const remaining = deadline - nowMs();
        if (remaining <= 0) return gridContains(driver, needle);
        _ = try driver.pumpMs(@intCast(@min(remaining, 50)));
        if (driver.exited and !gridContains(driver, needle)) {
            while (try driver.pumpMs(0)) {}
            return gridContains(driver, needle);
        }
    }
}

/// Pump until `needle` is ABSENT or `timeout_ms` elapses (the inverse of
/// `waitFor` — e.g. confirm a `clear` wiped a prior line before a snapshot).
pub fn waitForAbsent(driver: anytype, needle: []const u8, timeout_ms: u32) !bool {
    const deadline = nowMs() + @as(i64, timeout_ms);
    while (gridContains(driver, needle)) {
        const remaining = deadline - nowMs(); // capture once, then guard the cast
        if (remaining <= 0) return !gridContains(driver, needle);
        if (driver.exited) { // child gone: drain, then the screen can't change
            while (try driver.pumpMs(0)) {}
            return !gridContains(driver, needle);
        }
        _ = try driver.pumpMs(@intCast(@min(remaining, 50)));
    }
    return true;
}

/// Pump until `needle` appears at least `count` times or `timeout_ms` elapses.
/// For an async paint whose text also appears elsewhere (a ghost completing a
/// command still in scrollback): the count rises only when the new copy lands.
pub fn waitForCount(driver: anytype, needle: []const u8, count: usize, timeout_ms: u32) !bool {
    const deadline = nowMs() + @as(i64, timeout_ms);
    while (true) {
        if (gridCount(driver, needle) >= count) return true;
        const remaining = deadline - nowMs();
        if (remaining <= 0) return gridCount(driver, needle) >= count;
        _ = try driver.pumpMs(@intCast(@min(remaining, 50)));
        if (driver.exited and gridCount(driver, needle) < count) {
            while (try driver.pumpMs(0)) {}
            return gridCount(driver, needle) >= count;
        }
    }
}

/// Pump until output has been quiet for `quiet_ms` or `timeout_ms` elapses. The
/// quiet window resets on every byte, so a late async repaint (ghost text off a
/// keystroke) is still awaited. Returns true if it settled, false on timeout.
pub fn waitStable(driver: anytype, quiet_ms: u32, timeout_ms: u32) !bool {
    const deadline = nowMs() + @as(i64, timeout_ms);
    const quiet = @max(@as(i64, quiet_ms), 1); // floor: quiet_ms=0 must still pump once
    var quiet_since = nowMs();
    while (true) {
        if (nowMs() - quiet_since >= quiet) return true;
        if (nowMs() >= deadline) return false;
        const got = try driver.pumpMs(@intCast(@min(quiet, 25)));
        if (got) quiet_since = nowMs();
        if (driver.exited) {
            while (try driver.pumpMs(0)) {} // drain final output
            return true; // child gone → the screen is permanently stable
        }
    }
}

/// Sleep `ms`, pumping output so the grid stays current.
pub fn sleepMs(driver: anytype, ms: u32) !void {
    const deadline = nowMs() + @as(i64, ms);
    while (true) {
        const remaining = deadline - nowMs(); // capture once, then guard the cast
        if (remaining <= 0) return;
        _ = try driver.pumpMs(@intCast(@min(remaining, 50)));
    }
}

test {
    _ = @import("wait_tests.zig");
}
