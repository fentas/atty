const std = @import("std");
const testing = std.testing;
const uds = @import("uds.zig");

test "parse a get_metrics reply into Metrics" {
    const reply =
        "{\"type\":\"metrics\",\"aggregate\":{\"commands\":312,\"guard_block\":3," ++
        "\"ghost_accepted\":188},\"guard\":{\"profile\":\"session\",\"ebpf\":\"attached\"," ++
        "\"enforcement\":\"one_level\",\"atoms_version\":\"\",\"deny_path\":0," ++
        "\"deny_basename\":3},\"instances\":5}";

    const parsed = uds.parse(testing.allocator, reply) orelse return error.ParseFailed;
    defer parsed.deinit();
    const m = parsed.value;

    try testing.expectEqual(@as(u64, 312), m.aggregate.commands);
    try testing.expectEqual(@as(u64, 3), m.aggregate.guard_block);
    try testing.expectEqual(@as(u64, 188), m.aggregate.ghost_accepted);
    try testing.expectEqual(@as(u64, 5), m.instances);
    try testing.expectEqualStrings("session", m.guard.profile);
    try testing.expectEqualStrings("attached", m.guard.ebpf);
    try testing.expectEqual(@as(u32, 3), m.guard.deny_basename);
}

test "parse tolerates missing fields (defaults) + ignores unknown" {
    // A sparse reply with an unknown extra field — must still parse.
    const reply = "{\"type\":\"metrics\",\"guard\":{\"profile\":\"prompt\"},\"extra\":42}";
    const parsed = uds.parse(testing.allocator, reply) orelse return error.ParseFailed;
    defer parsed.deinit();
    try testing.expectEqualStrings("prompt", parsed.value.guard.profile);
    try testing.expectEqual(@as(u64, 0), parsed.value.aggregate.commands);
    try testing.expectEqual(@as(u64, 0), parsed.value.instances);
}

test "parse rejects malformed json" {
    try testing.expect(uds.parse(testing.allocator, "{not json") == null);
}
