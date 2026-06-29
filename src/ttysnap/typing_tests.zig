const std = @import("std");
const testing = std.testing;
const typing = @import("typing.zig");

/// Driver stand-in: counts sends + accumulates the bytes. pumpMs is a no-op
/// (the paced patterns sleep on the real clock; tests use short text so the
/// busy-wait is bounded to a few tens of ms).
const Fake = struct {
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    sends: usize = 0,
    pub fn send(self: *Fake, bytes: []const u8) !void {
        self.sends += 1;
        try self.out.appendSlice(self.alloc, bytes);
    }
    pub fn pumpMs(self: *Fake, _: i32) !bool {
        _ = self;
        return false;
    }
};

fn fake(out: *std.ArrayList(u8)) Fake {
    return .{ .out = out, .alloc = testing.allocator };
}

test "typing: instant sends the whole text in one shot" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var f = fake(&out);
    try typing.typeText(&f, "echo hi", .instant);
    try testing.expectEqual(@as(usize, 1), f.sends);
    try testing.expectEqualStrings("echo hi", out.items);
}

test "typing: a paced pattern sends one keystroke per codepoint, text intact" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var f = fake(&out);
    try typing.typeText(&f, "hi!", .fast);
    try testing.expectEqual(@as(usize, 3), f.sends);
    try testing.expectEqualStrings("hi!", out.items);
}

test "typing: UTF-8 codepoints are sent whole, never split mid-sequence" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var f = fake(&out);
    try typing.typeText(&f, "é!", .fast); // "é" = 2 bytes → 1 send; "!" → 1 send
    try testing.expectEqual(@as(usize, 2), f.sends);
    try testing.expectEqualStrings("é!", out.items);
}

test "typing: Pattern.fromName parses the names, null on unknown" {
    try testing.expectEqual(typing.Pattern.irregular, typing.Pattern.fromName("irregular").?);
    try testing.expectEqual(typing.Pattern.instant, typing.Pattern.fromName("instant").?);
    try testing.expectEqual(typing.Pattern.random, typing.Pattern.fromName("random").?);
    try testing.expect(typing.Pattern.fromName("bogus") == null);
}
