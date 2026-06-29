const std = @import("std");
const testing = std.testing;
const wait = @import("wait.zig");

/// A driver stand-in: a screen string the pumps can mutate, plus an `exited`
/// flag — the duck-typed interface `wait`'s generics require (gridText/pumpMs/
/// exited). No real PTY, so the condition loops are exercised deterministically.
const Fake = struct {
    screen: []const u8 = "",
    exited: bool = false,
    pumps: usize = 0,
    flip_at: usize = 0, // on this pump, set screen = flip_to (0 = never)
    flip_to: []const u8 = "",
    noisy: usize = 0, // pumpMs reports "got bytes" for this many pumps, then quiet

    pub fn gridText(self: *Fake) []const u8 {
        return self.screen;
    }
    pub fn pumpMs(self: *Fake, _: i32) !bool {
        self.pumps += 1;
        if (self.flip_at != 0 and self.pumps == self.flip_at) self.screen = self.flip_to;
        return self.pumps <= self.noisy;
    }
};

test "wait: gridContains + gridCount (incl. empty-needle guard)" {
    var f = Fake{ .screen = "a-b-a-b-a" };
    try testing.expect(wait.gridContains(&f, "b-a"));
    try testing.expect(!wait.gridContains(&f, "zzz"));
    try testing.expectEqual(@as(usize, 3), wait.gridCount(&f, "a"));
    try testing.expectEqual(@as(usize, 0), wait.gridCount(&f, "")); // no infinite loop
}

test "wait: waitFor returns true when the needle appears via pumps" {
    var f = Fake{ .screen = "loading", .flip_at = 3, .flip_to = "ready" };
    try testing.expect(try wait.waitFor(&f, "ready", 5000));
    try testing.expectEqual(@as(usize, 3), f.pumps);
}

test "wait: waitFor times out (false) when the needle never appears" {
    var f = Fake{ .screen = "loading" };
    try testing.expect(!(try wait.waitFor(&f, "nope", 15)));
}

test "wait: waitFor drains + returns fast once the child has exited" {
    var f = Fake{ .screen = "x", .exited = true };
    // Huge timeout, but the exited drain returns immediately rather than spinning.
    try testing.expect(!(try wait.waitFor(&f, "needle", 100000)));
}

test "wait: waitForAbsent returns true when the needle clears" {
    var f = Fake{ .screen = "busy", .flip_at = 2, .flip_to = "idle" };
    try testing.expect(try wait.waitForAbsent(&f, "busy", 5000));
}

test "wait: waitForCount waits for the Nth occurrence" {
    var f = Fake{ .screen = "x", .flip_at = 2, .flip_to = "x x x" };
    try testing.expect(try wait.waitForCount(&f, "x", 3, 5000));
}

test "wait: waitStable settles after the output goes quiet" {
    var f = Fake{ .screen = "done", .noisy = 3 }; // 3 noisy pumps, then quiet
    try testing.expect(try wait.waitStable(&f, 10, 5000));
    try testing.expect(f.pumps > 3); // pumped past the noisy window into the quiet one
}
