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
    try testing.expectError(error.BadReport, replay.parse(testing.allocator, "{\"atty_version\":\"x\"}")); // no streams key
    try testing.expectError(error.BadReport, replay.parse(testing.allocator, "{\"streams\":5}")); // streams not an array
    // An empty streams array is a valid (0-event) report, not an error.
    var rep = try replay.parse(testing.allocator, "{\"streams\":[]}");
    rep.deinit();
}

test "replay: code points > 0xFF preserve their UTF-8 bytes (foreign report)" {
    const json =
        \\{ "atty_version":"x", "terminal":{"cols":1,"rows":1}, "streams":[[0.0,"term","éἀ"]] }
    ;
    var rep = try replay.parse(testing.allocator, json);
    defer rep.deinit();
    const term = try replay.streamBytes(&rep, .term, testing.allocator);
    defer testing.allocator.free(term);
    // U+00E9 → one byte 0xE9; U+1F00 (>0xFF, not atty-emitted) → its 3 UTF-8 bytes.
    try testing.expectEqual(@as(usize, 4), term.len);
    try testing.expectEqual(@as(u8, 0xE9), term[0]);
}

test "replay run: exit codes for bad invocations" {
    const a = testing.allocator;
    try testing.expectEqual(@as(u8, 2), replay.run(a, &.{"frobnicate"})); // unknown verb
    try testing.expectEqual(@as(u8, 2), replay.run(a, &.{"replay"})); // missing path
    try testing.expectEqual(@as(u8, 2), replay.run(a, &.{ "replay", "x.json", "--stream", "bogus" })); // bad stream
    try testing.expectEqual(@as(u8, 2), replay.run(a, &.{ "replay", "x.json", "--nope" })); // unknown flag
    try testing.expectEqual(@as(u8, 2), replay.run(a, &.{ "replay", "a.json", "b.json" })); // extra positional
    try testing.expectEqual(@as(u8, 1), replay.run(a, &.{ "replay", "/no/such/report-xyz.json" })); // unreadable
    // --stream= form is accepted (reaches the unreadable-file path → 1, not unknown-flag → 2)
    try testing.expectEqual(@as(u8, 1), replay.run(a, &.{ "replay", "/no/such/report-xyz.json", "--stream=shell" }));
    try testing.expectEqual(@as(u8, 2), replay.run(a, &.{ "replay", "x.json", "--stream=bogus" })); // bad = value
}

// run() writes to fd 1; during `zig build test` fd 1 is the test-runner IPC
// channel, so redirect it to /dev/null for the success path (which emits output)
// to avoid corrupting the protocol.
extern "c" fn dup(fd: c_int) c_int;
extern "c" fn dup2(old: c_int, new: c_int) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;

test "replay run: happy path returns 0 for a real saved report" {
    const a = testing.allocator;
    var r = try rec.Recorder.init(a, 4096);
    defer r.deinit();
    r.push(.term, 0, "hi\n");
    const path = try report.save(a, "/tmp/atty-replay-selftest", .{
        .atty_version = "t",
        .cols = 1,
        .rows = 1,
        .term = "",
        .shell = "",
        .lang = "",
        .line_buffer = "",
        .line_cursor = 0,
        .line_uncertain = false,
        .incognito = false,
    }, &r);
    defer a.free(path);
    const path_z = try a.dupeZ(u8, path);
    defer a.free(path_z);
    defer _ = unlink(path_z.ptr); // don't leave a test artifact behind

    const O_WRONLY: c_int = @bitCast(std.posix.O{ .ACCMODE = .WRONLY });
    const devnull = open("/dev/null", O_WRONLY);
    if (devnull < 0) return error.OpenFailed;
    const saved = dup(1);
    defer {
        _ = dup2(saved, 1);
        _ = std.c.close(saved);
        _ = std.c.close(devnull);
    }
    _ = dup2(devnull, 1);

    try testing.expectEqual(@as(u8, 0), replay.run(a, &.{ "replay", path, "--info" }));
    try testing.expectEqual(@as(u8, 0), replay.run(a, &.{ "replay", path, "--fast" })); // replays term "hi\n"
    try testing.expectEqual(@as(u8, 0), replay.run(a, &.{ "replay", path, "--stream", "shell", "--fast" }));
}
