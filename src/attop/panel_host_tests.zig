const std = @import("std");
const testing = std.testing;
const panel = @import("panel.zig");
const PanelHost = @import("panel_host.zig").PanelHost;

// Two fake panels exercising the hook surface: A has onKey + state; B omits
// onKey (so keyAt must default to .pass) and votes for start-focus.
const PanelA = struct {
    pub const Runtime = struct { attached: bool = false };
    pub fn attach(_: std.mem.Allocator) !Runtime {
        return .{ .attached = true };
    }
    pub fn title() []const u8 {
        return "Alpha";
    }
    pub fn navKey() u8 {
        return 'a';
    }
    pub fn render(_: *Runtime, _: *panel.Ctx, w: *std.Io.Writer) !void {
        try w.writeAll("A");
    }
    pub fn onKey(_: *Runtime, _: *panel.Ctx, k: panel.Key) !panel.Action {
        return switch (k) {
            .char => |c| if (c == 'x') .handled else .pass,
            else => .pass,
        };
    }
    pub fn footerHint(_: *Runtime, _: *panel.Ctx) ?[]const u8 {
        return "alpha-hint";
    }
};

const PanelB = struct {
    pub const Runtime = struct {};
    pub fn attach(_: std.mem.Allocator) !Runtime {
        return .{};
    }
    pub fn title() []const u8 {
        return "Beta";
    }
    pub fn navKey() u8 {
        return 'b';
    }
    pub fn render(_: *Runtime, _: *panel.Ctx, w: *std.Io.Writer) !void {
        try w.writeAll("B");
    }
    pub fn wantsFocusAtStart(_: *panel.Ctx) bool {
        return true;
    }
};

const Host = PanelHost(.{ PanelA, PanelB });

fn testCtx(arena: std.mem.Allocator) panel.Ctx {
    return .{ .arena = arena };
}

test "PanelHost: count + comptime metadata" {
    try testing.expectEqual(@as(usize, 2), Host.count);
    try testing.expectEqualStrings("Alpha", Host.titleAt(0));
    try testing.expectEqualStrings("Beta", Host.titleAt(1));
    try testing.expectEqual(@as(u8, 'a'), Host.navKeyAt(0));
    try testing.expectEqual(@as(u8, 'b'), Host.navKeyAt(1));
    try testing.expectEqual(@as(?usize, 0), Host.indexForKey('a'));
    try testing.expectEqual(@as(?usize, 1), Host.indexForKey('b'));
    try testing.expectEqual(@as(?usize, null), Host.indexForKey('z'));
}

test "PanelHost: attach/detach + render targets the right panel" {
    var rts = try Host.attachAll(testing.allocator);
    defer Host.detachAll(testing.allocator, &rts);
    try testing.expect(rts[0].attached); // PanelA.attach ran

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = testCtx(arena.allocator());

    var bufa: [8]u8 = undefined;
    var wa = std.Io.Writer.fixed(&bufa);
    try Host.renderAt(&rts, &ctx, 0, &wa);
    try testing.expectEqualStrings("A", bufa[0..wa.end]);

    var bufb: [8]u8 = undefined;
    var wb = std.Io.Writer.fixed(&bufb);
    try Host.renderAt(&rts, &ctx, 1, &wb);
    try testing.expectEqualStrings("B", bufb[0..wb.end]);
}

test "PanelHost: keyAt routes to panel; missing onKey defaults to .pass" {
    var rts = try Host.attachAll(testing.allocator);
    defer Host.detachAll(testing.allocator, &rts);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = testCtx(arena.allocator());

    try testing.expectEqual(panel.Action.handled, try Host.keyAt(&rts, &ctx, 0, .{ .char = 'x' }));
    try testing.expectEqual(panel.Action.pass, try Host.keyAt(&rts, &ctx, 0, .{ .char = 'y' }));
    // PanelB has no onKey → host must synthesise .pass.
    try testing.expectEqual(panel.Action.pass, try Host.keyAt(&rts, &ctx, 1, .{ .char = 'x' }));
}

test "PanelHost: footerHintAt only for panels that declare it" {
    var rts = try Host.attachAll(testing.allocator);
    defer Host.detachAll(testing.allocator, &rts);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = testCtx(arena.allocator());

    try testing.expectEqualStrings("alpha-hint", Host.footerHintAt(&rts, &ctx, 0).?);
    try testing.expectEqual(@as(?[]const u8, null), Host.footerHintAt(&rts, &ctx, 1));
}

test "PanelHost: landingIndex honors the first wantsFocusAtStart vote" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = testCtx(arena.allocator());
    // PanelA doesn't vote, PanelB votes true → index 1.
    try testing.expectEqual(@as(usize, 1), Host.landingIndex(&ctx));
}
