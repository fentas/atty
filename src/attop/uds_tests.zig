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

test "guard.features wire contract: absent → null, [] → empty, list → values" {
    // absent (older daemon) → null (the dashboard shows "unknown", not minimal)
    const absent = "{\"type\":\"metrics\",\"guard\":{\"profile\":\"strict\"},\"instances\":1}";
    const pa = uds.parse(testing.allocator, absent) orelse return error.ParseFailed;
    defer pa.deinit();
    try testing.expect(pa.value.guard.features == null);

    // present-empty (new daemon, default build) → an empty (non-null) slice
    const empty = "{\"type\":\"metrics\",\"guard\":{\"profile\":\"strict\",\"features\":[]},\"instances\":1}";
    const pe = uds.parse(testing.allocator, empty) orelse return error.ParseFailed;
    defer pe.deinit();
    try testing.expect(pe.value.guard.features != null);
    try testing.expectEqual(@as(usize, 0), pe.value.guard.features.?.len);

    // present-list → the values, in order
    const list = "{\"type\":\"metrics\",\"guard\":{\"profile\":\"strict\",\"features\":[\"ebpf\",\"osv-live\"]},\"instances\":1}";
    const pl = uds.parse(testing.allocator, list) orelse return error.ParseFailed;
    defer pl.deinit();
    const f = pl.value.guard.features orelse return error.NoFeatures;
    try testing.expectEqual(@as(usize, 2), f.len);
    try testing.expectEqualStrings("ebpf", f[0]);
    try testing.expectEqualStrings("osv-live", f[1]);
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

test "parse a list_instances reply into InstancesReply" {
    const reply =
        "{\"type\":\"instances\",\"instances\":[" ++
        "{\"uid\":1000,\"pid\":4242,\"cwd\":\"/proj\",\"shell\":\"bash\"," ++
        "\"incognito\":false,\"last_seen_ms\":1,\"counters\":{\"commands\":12}}," ++
        "{\"uid\":1000,\"pid\":99,\"shell\":\"zsh\",\"incognito\":true," ++
        "\"counters\":{\"commands\":3}}]}";
    const parsed = uds.parseInto(uds.InstancesReply, testing.allocator, reply) orelse return error.ParseFailed;
    defer parsed.deinit();
    const inst = parsed.value.instances;
    try testing.expectEqual(@as(usize, 2), inst.len);
    try testing.expectEqual(@as(u32, 4242), inst[0].pid);
    try testing.expectEqualStrings("bash", inst[0].shell);
    try testing.expectEqualStrings("/proj", inst[0].cwd);
    try testing.expectEqual(@as(u64, 12), inst[0].counters.commands);
    try testing.expect(inst[1].incognito);
}

test "parse rejects malformed json" {
    try testing.expect(uds.parse(testing.allocator, "{not json") == null);
}
