const std = @import("std");
const testing = std.testing;
const report = @import("debug_report.zig");
const rec = @import("debug_recorder.zig");

test "report: valid JSON with meta, escaping, and rebased stream timestamps" {
    var r = try rec.Recorder.init(testing.allocator, 4096);
    defer r.deinit();
    r.push(.in, 1000, "ls");
    r.push(.shell, 1100, "a\tb\n");
    r.push(.term, 1200, "\x1b[K");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try report.write(&out, testing.allocator, .{
        .atty_version = "9.9.9",
        .cols = 80,
        .rows = 24,
        .term = "xterm-256color",
        .shell = "/bin/bash",
        .lang = "C.UTF-8",
        .line_buffer = "ec\"ho",
        .line_cursor = 5,
        .line_uncertain = false,
        .incognito = false,
    }, &r);
    const s = out.items;

    // Must be valid JSON (proves escaping is correct).
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, s, .{});
    defer parsed.deinit();

    try testing.expect(std.mem.indexOf(u8, s, "\"atty_version\": \"9.9.9\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"cols\": 80") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"TERM\": \"xterm-256color\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "ec\\\"ho") != null); // quote escaped in line_buffer
    try testing.expect(std.mem.indexOf(u8, s, "[0.000, \"in\", \"ls\"]") != null); // first event rebased to 0
    try testing.expect(std.mem.indexOf(u8, s, "[0.100, \"shell\", \"a\\tb\\n\"]") != null); // tab/newline escaped
    try testing.expect(std.mem.indexOf(u8, s, "\\u001b") != null); // ESC escaped
}
