const std = @import("std");
const testing = std.testing;
const mod = @import("warn_subscriber.zig");
const Subscriber = mod.Subscriber;
const Event = mod.Event;

fn mkEvent(allocator: std.mem.Allocator, pid: u32) !Event {
    return .{
        .pid = pid,
        .ppid = 1,
        .comm = try allocator.dupe(u8, "bash"),
        .argv0 = try allocator.dupe(u8, "/bin/ls"),
        .timestamp_ms = 42,
    };
}

test "subscriber starts empty" {
    var sub = Subscriber.init(testing.allocator, "/tmp/nope", 0);
    defer sub.stop();
    try testing.expectEqual(@as(usize, 0), sub.count());
    try testing.expectEqual(@as(u32, 0), sub.droppedTotal());
}

test "injectForTesting appends to ring" {
    var sub = Subscriber.init(testing.allocator, "/tmp/nope", 0);
    defer sub.stop();
    try sub.injectForTesting(try mkEvent(testing.allocator, 100));
    try sub.injectForTesting(try mkEvent(testing.allocator, 101));
    try testing.expectEqual(@as(usize, 2), sub.count());
    try testing.expectEqual(@as(u32, 0), sub.droppedTotal());
}

test "ring drops oldest at cap + bumps dropped_total" {
    var sub = Subscriber.init(testing.allocator, "/tmp/nope", 0);
    defer sub.stop();
    // Fill past cap.
    var i: u32 = 0;
    while (i < mod.RING_CAP + 5) : (i += 1) {
        try sub.injectForTesting(try mkEvent(testing.allocator, i));
    }
    try testing.expectEqual(mod.RING_CAP, sub.count());
    try testing.expectEqual(@as(u32, 5), sub.droppedTotal());
    // Newest 5 (RING_CAP, RING_CAP+1, ...) should be present;
    // oldest 5 (0..4) dropped.
    const snap = try sub.snapshot(testing.allocator);
    defer Subscriber.freeSnapshot(testing.allocator, snap);
    try testing.expectEqual(@as(u32, 5), snap[0].pid);
}

test "clear empties the buffer but preserves dropped_total" {
    var sub = Subscriber.init(testing.allocator, "/tmp/nope", 0);
    defer sub.stop();
    var i: u32 = 0;
    while (i < mod.RING_CAP + 3) : (i += 1) {
        try sub.injectForTesting(try mkEvent(testing.allocator, i));
    }
    try testing.expectEqual(@as(u32, 3), sub.droppedTotal());

    sub.clear();
    try testing.expectEqual(@as(usize, 0), sub.count());
    // dropped_total is a session-wide audit counter — clear() must NOT reset it.
    try testing.expectEqual(@as(u32, 3), sub.droppedTotal());

    // Buffer is reusable after clear.
    try sub.injectForTesting(try mkEvent(testing.allocator, 7));
    try testing.expectEqual(@as(usize, 1), sub.count());
}

test "snapshot returns independent copies" {
    var sub = Subscriber.init(testing.allocator, "/tmp/nope", 0);
    defer sub.stop();
    try sub.injectForTesting(try mkEvent(testing.allocator, 999));
    const snap = try sub.snapshot(testing.allocator);
    defer Subscriber.freeSnapshot(testing.allocator, snap);
    try testing.expectEqual(@as(usize, 1), snap.len);
    try testing.expectEqual(@as(u32, 999), snap[0].pid);
    try testing.expectEqualStrings("bash", snap[0].comm);
    try testing.expectEqualStrings("/bin/ls", snap[0].argv0);
    // Mutate snap — the buffer must stay intact.
    snap[0].pid = 0;
    const snap2 = try sub.snapshot(testing.allocator);
    defer Subscriber.freeSnapshot(testing.allocator, snap2);
    try testing.expectEqual(@as(u32, 999), snap2[0].pid);
}

// --- Wire-format parsing tests ---------------------------------
//
// These exercise the JSON-by-string-matching path so a daemon-side
// rename of `pid` / `ppid` / `comm` / `argv0` / `timestamp_ms` is
// caught loudly. The atty-guard side has its own serde tests; this
// is the inverse — the substring shapes are the de-facto contract
// across the languages.

const parseWarnEvent = struct {
    // Reach the private parser via the test target's access to
    // file-internal items.
    pub fn call(allocator: std.mem.Allocator, line: []const u8) !Event {
        // Reconstruct from a fake-publish via the public injectForTesting
        // round trip — exercises the same parsing path the runLoop uses.
        return @import("warn_subscriber.zig").parseWarnEventForTesting(allocator, line);
    }
}.call;

test "parses warn_event line shape" {
    const line =
        \\{"id":0,"type":"warn_event","pid":1234,"ppid":5678,"comm":"bash","argv0":"/bin/ls","timestamp_ms":99}
    ;
    const evt = try parseWarnEvent(testing.allocator, line);
    var owned = evt;
    defer owned.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1234), evt.pid);
    try testing.expectEqual(@as(u32, 5678), evt.ppid);
    try testing.expectEqualStrings("bash", evt.comm);
    try testing.expectEqualStrings("/bin/ls", evt.argv0);
    try testing.expectEqual(@as(u64, 99), evt.timestamp_ms);
}

test "rejects malformed line missing pid" {
    const line =
        \\{"type":"warn_event","ppid":1,"comm":"x","argv0":"y","timestamp_ms":0}
    ;
    const result = parseWarnEvent(testing.allocator, line);
    try testing.expectError(error.FieldMissing, result);
}

test "unescapes JSON string fields" {
    // argv0 with embedded quote + newline + backslash — should
    // decode to the raw bytes, not the literal escape sequences.
    const line =
        \\{"id":0,"type":"warn_event","pid":1,"ppid":1,"comm":"bash","argv0":"echo \"hi\"\nls","timestamp_ms":0}
    ;
    const evt = try parseWarnEvent(testing.allocator, line);
    var owned = evt;
    defer owned.deinit(testing.allocator);
    try testing.expectEqualStrings("echo \"hi\"\nls", evt.argv0);
}
