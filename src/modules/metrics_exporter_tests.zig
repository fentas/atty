const std = @import("std");
const testing = std.testing;
const mod = @import("metrics_exporter.zig");

const IncognitoPolicy = mod.IncognitoPolicy;
const Counters = mod.Counters;
const incognitoSkip = mod.incognitoSkip;
const incognitoRedact = mod.incognitoRedact;
const shouldCount = mod.shouldCount;
const redactedCounters = mod.redactedCounters;
const jsonEscapeInto = mod.jsonEscapeInto;
const buildReportJson = mod.buildReportJson;

test "configured module type compiles" {
    // configure() is generic — its body (attach/onTick/report/cwdOf/sendUds)
    // is only analyzed when instantiated, and the module isn't in the
    // default tuple, so force semantic analysis here.
    const M = mod.configure(.{});
    testing.refAllDecls(M);
    const rt: M.Runtime = .{ .allocator = testing.allocator, .pid = 1, .shell = "" };
    try testing.expectEqual(@as(u64, 0), rt.counters.commands);
}

test "incognito policy matrix" {
    // Not incognito → never skip / redact + always count, whatever the policy.
    for ([_]IncognitoPolicy{ .nothing, .security_only, .normal }) |p| {
        try testing.expect(!incognitoSkip(false, p));
        try testing.expect(!incognitoRedact(false, p));
        try testing.expect(shouldCount(false, p));
    }
    // Incognito: nothing→skip, security_only→redact, normal→neither.
    try testing.expect(incognitoSkip(true, .nothing));
    try testing.expect(!incognitoRedact(true, .nothing));
    try testing.expect(!incognitoSkip(true, .security_only));
    try testing.expect(incognitoRedact(true, .security_only));
    try testing.expect(!incognitoSkip(true, .normal));
    try testing.expect(!incognitoRedact(true, .normal));
    // Counting: incognito under a non-normal policy is not counted.
    try testing.expect(!shouldCount(true, .nothing));
    try testing.expect(!shouldCount(true, .security_only));
    try testing.expect(shouldCount(true, .normal));
}

test "redactedCounters keeps guard_*, drops productivity" {
    const full: Counters = .{
        .commands = 9,
        .ghost_accepted = 5,
        .ghost_shown = 7,
        .keystrokes_saved = 100,
        .llm_calls = 3,
        .guard_warn = 2,
        .guard_block = 1,
        .guard_refused = 4,
    };
    const r = redactedCounters(full);
    // productivity zeroed
    try testing.expectEqual(@as(u64, 0), r.commands);
    try testing.expectEqual(@as(u64, 0), r.ghost_accepted);
    try testing.expectEqual(@as(u64, 0), r.ghost_shown);
    try testing.expectEqual(@as(u64, 0), r.keystrokes_saved);
    try testing.expectEqual(@as(u64, 0), r.llm_calls);
    // security counters preserved
    try testing.expectEqual(@as(u64, 2), r.guard_warn);
    try testing.expectEqual(@as(u64, 1), r.guard_block);
    try testing.expectEqual(@as(u64, 4), r.guard_refused);
}

test "jsonEscapeInto escapes quote+backslash, drops controls" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("a\\\"b\\\\c", jsonEscapeInto(&buf, "a\"b\\c"));
    // control chars (newline, tab, NUL) dropped
    try testing.expectEqualStrings("ab", jsonEscapeInto(&buf, "a\n\t\x00b"));
    // plain path passes through
    try testing.expectEqualStrings("/home/u/p", jsonEscapeInto(&buf, "/home/u/p"));
}

test "jsonEscapeInto truncates on a small dst without overflow" {
    var tiny: [3]u8 = undefined;
    // A quote needs 2 bytes; the second quote won't fit in 3 → stops clean.
    const out = jsonEscapeInto(&tiny, "\"\"\"");
    try testing.expect(out.len <= tiny.len);
}

test "buildReportJson emits the wire shape + reflects redaction" {
    var buf: [1024]u8 = undefined;
    var buf2: [1024]u8 = undefined;
    const c: Counters = .{ .commands = 12, .guard_block = 1 };
    const line = try buildReportJson(&buf, 4242, "/proj", "bash", false, c);
    // newline-framed, the method + key fields present
    try testing.expect(std.mem.endsWith(u8, line, "}\n"));
    try testing.expect(std.mem.indexOf(u8, line, "\"method\":\"report_metrics\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"pid\":4242") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"cwd\":\"/proj\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"commands\":12") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"incognito\":false") != null);

    // A redacted report: zeroed productivity, blanked cwd, kept guard_block.
    const r = try buildReportJson(&buf2, 4242, "", "bash", true, redactedCounters(c));
    try testing.expect(std.mem.indexOf(u8, r, "\"commands\":0") != null);
    try testing.expect(std.mem.indexOf(u8, r, "\"cwd\":\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, r, "\"guard_block\":1") != null);
    try testing.expect(std.mem.indexOf(u8, r, "\"incognito\":true") != null);

    // valid JSON (drop the trailing \n) per the std parser
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line[0 .. line.len - 1], .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}
