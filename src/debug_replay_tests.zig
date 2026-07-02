const std = @import("std");
const testing = std.testing;
const replay = @import("debug_replay.zig");
const report = @import("debug_report.zig");
const rec = @import("debug_recorder.zig");

test "replay: parse round-trips a report's streams byte-exactly" {
    var r = try rec.Recorder.init(testing.allocator, 8192);
    defer r.deinit();
    const term_bytes = "\x1b[Kok\xc3\x28\xff\"end\n"; // ESC, invalid-UTF-8, 0xff, quote, newline
    r.push(.in, 1000, "ls\r");
    r.push(.term, 1100, term_bytes);
    r.push(.shell, 1200, "hello");

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(testing.allocator);
    try report.write(&json, testing.allocator, .{
        .atty_version = "1.2.3",
        .cols = 80,
        .rows = 24,
        .term = "xterm",
        .shell = "/bin/bash",
        .lang = "C",
        .line_buffer = "",
        .line_cursor = 0,
        .line_uncertain = false,
        .incognito = false,
    }, &r);

    var rep = try replay.parse(testing.allocator, json.items);
    defer rep.deinit();
    try testing.expectEqualStrings("1.2.3", rep.atty_version);
    try testing.expectEqual(@as(u16, 80), rep.cols);
    try testing.expectEqual(@as(u16, 24), rep.rows);

    const term = try replay.streamBytes(&rep, .term, testing.allocator);
    defer testing.allocator.free(term);
    try testing.expectEqualStrings(term_bytes, term); // byte-exact through encode→JSON→decode

    const in = try replay.streamBytes(&rep, .in, testing.allocator);
    defer testing.allocator.free(in);
    try testing.expectEqualStrings("ls\r", in);
}

test "replay: rejects non-report input" {
    try testing.expectError(error.BadReport, replay.parse(testing.allocator, "not json at all"));
    try testing.expectError(error.BadReport, replay.parse(testing.allocator, "[1,2,3]")); // valid JSON, not an object
}
