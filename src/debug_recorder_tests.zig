const std = @import("std");
const testing = std.testing;
const rec = @import("debug_recorder.zig");
const Recorder = rec.Recorder;
const Stream = rec.Stream;

const Collector = struct { out: *std.ArrayList(u8), alloc: std.mem.Allocator };
fn collect(c: *Collector, ts: i64, s: Stream, data: []const u8) void {
    _ = ts;
    c.out.appendSlice(c.alloc, s.name()) catch return;
    c.out.append(c.alloc, ':') catch return;
    c.out.appendSlice(c.alloc, data) catch return;
    c.out.append(c.alloc, ';') catch return;
}

test "recorder: records round-trip oldest→newest with stream + data intact" {
    var r = try Recorder.init(testing.allocator, 4096);
    defer r.deinit();
    r.push(.in, 1, "abc");
    r.push(.shell, 2, "def");
    r.push(.term, 3, "ghi");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var c = Collector{ .out = &out, .alloc = testing.allocator };
    r.forEach(&c, collect);
    try testing.expectEqualStrings("in:abc;shell:def;term:ghi;", out.items);
}

test "recorder: a record larger than a half is dropped (bumps dropped)" {
    var r = try Recorder.init(testing.allocator, 32);
    defer r.deinit();
    r.push(.in, 1, "x" ** 200);
    try testing.expectEqual(@as(u64, 1), r.dropped);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var c = Collector{ .out = &out, .alloc = testing.allocator };
    r.forEach(&c, collect);
    try testing.expectEqualStrings("", out.items);
}

test "recorder: double-buffer keeps a bounded, newest-biased window" {
    var r = try Recorder.init(testing.allocator, 96); // small halves → forced swaps
    defer r.deinit();
    var i: u32 = 0;
    while (i < 60) : (i += 1) {
        var buf: [3]u8 = undefined;
        r.push(.in, @intCast(i), std.fmt.bufPrint(&buf, "{d:0>3}", .{i}) catch unreachable);
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var c = Collector{ .out = &out, .alloc = testing.allocator };
    r.forEach(&c, collect);
    try testing.expect(std.mem.indexOf(u8, out.items, "in:059;") != null); // newest kept
    try testing.expect(std.mem.indexOf(u8, out.items, "in:000;") == null); // oldest evicted
    try testing.expect(std.mem.count(u8, out.items, ";") < 30); // bounded, not all 60
}

test "recorder: pushNow drops records while paused (incognito)" {
    var r = try Recorder.init(testing.allocator, 4096);
    defer r.deinit();
    r.pushNow(.in, "before");
    r.paused = true;
    r.pushNow(.in, "during-incognito");
    r.paused = false;
    r.pushNow(.in, "after");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var c = Collector{ .out = &out, .alloc = testing.allocator };
    r.forEach(&c, collect);
    try testing.expect(std.mem.indexOf(u8, out.items, "before") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "during-incognito") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "after") != null);
}
