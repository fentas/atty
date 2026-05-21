//! Tests for `modules/llm/chat_persist.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("chat_persist.zig");

// Imports mirrored from the source file (tests reference
// these module-level names by bare identifier).
const dialog = @import("dialog.zig");

// libc externs duplicated from the source rather than re-bound
// via `mod.*` — keeps the source's surface minimal (these are
// implementation details, not module API).
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn lseek(fd: c_int, offset: i64, whence: c_int) i64;
extern "c" fn rename(old_path: [*:0]const u8, new_path: [*:0]const u8) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;

// O_* flags — Linux values.
const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0o100;
const O_APPEND: c_int = 0o2000;

// Re-binds of pub decls so test bodies stay short.
const appendTurn = mod.appendTurn;
const LoadedTurn = mod.LoadedTurn;
const loadLastTurns = mod.loadLastTurns;
const parseLine = mod.parseLine;
const resolvePath = mod.resolvePath;
const rotateIfExceeded = mod.rotateIfExceeded;

test "parseLine: user turn round-trips through JSON" {
    const line = "{\"kind\":\"user\",\"content\":\"list files\"}";
    const t = try parseLine(testing.allocator, line);
    defer testing.allocator.free(t.content);
    try testing.expectEqual(dialog.TurnKind.user, t.kind);
    try testing.expectEqualStrings("list files", t.content);
}

test "parseLine: rejects unknown kind" {
    const line = "{\"kind\":\"weather_forecast\",\"content\":\"sunny\"}";
    try testing.expectError(error.UnknownTurnKind, parseLine(testing.allocator, line));
}

test "parseLine: content with quotes + newlines round-trips" {
    const line = "{\"kind\":\"assistant_exec\",\"content\":\"line1\\nline2 with \\\"quotes\\\"\"}";
    const t = try parseLine(testing.allocator, line);
    defer testing.allocator.free(t.content);
    try testing.expectEqualStrings("line1\nline2 with \"quotes\"", t.content);
}

test "appendTurn + loadLastTurns: round-trip a few turns" {
    // Use the system temp dir for a real file round-trip — keeps the
    // I/O code path tested end-to-end rather than mocked.
    var name_buf: [64]u8 = undefined;
    // Test-fixture uniqueness — pid + ts via clock_gettime. Tests
    // don't run in parallel against the same file; `unlink` clears
    // it below.
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    const seed: u64 = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    const name = try std.fmt.bufPrint(&name_buf, "/tmp/atty-chat-test-{x}.jsonl", .{seed});
    const name_z = try testing.allocator.dupeZ(u8, name);
    defer testing.allocator.free(name_z);
    defer _ = std.c.unlink(name_z.ptr);

    try testing.expect(appendTurn(testing.allocator, name, .user, "hello"));
    try testing.expect(appendTurn(testing.allocator, name, .assistant_exec, "{\"action\":\"done\"}"));
    try testing.expect(appendTurn(testing.allocator, name, .observation, "out: 42"));

    var loaded = try loadLastTurns(testing.allocator, name, 10, 1 << 20);
    defer {
        for (loaded.items) |t| testing.allocator.free(t.content);
        loaded.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 3), loaded.items.len);
    try testing.expectEqual(dialog.TurnKind.user, loaded.items[0].kind);
    try testing.expectEqualStrings("hello", loaded.items[0].content);
    try testing.expectEqual(dialog.TurnKind.assistant_exec, loaded.items[1].kind);
    try testing.expectEqualStrings("{\"action\":\"done\"}", loaded.items[1].content);
    try testing.expectEqual(dialog.TurnKind.observation, loaded.items[2].kind);
    try testing.expectEqualStrings("out: 42", loaded.items[2].content);
}

test "loadLastTurns: file larger than max_bytes loads TAIL (not head)" {
    // Regression for #187 finding 005: before the fix, loadLastTurns
    // read from offset 0 until max_bytes then reverse-walked that
    // HEAD prefix. For files larger than max_bytes that returned
    // the NEWEST turns IN THE FIRST CHUNK — i.e., stale older
    // turns, not the actual most-recent ones. The fix seeks to
    // `size - max_bytes` and parses the tail window.
    var name_buf: [64]u8 = undefined;
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    const seed: u64 = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    const name = try std.fmt.bufPrint(&name_buf, "/tmp/atty-chat-seek-test-{x}.jsonl", .{seed});
    const name_z = try testing.allocator.dupeZ(u8, name);
    defer testing.allocator.free(name_z);
    defer _ = std.c.unlink(name_z.ptr);

    // Write 100 turns. Each line is ~30 bytes after JSON wrapping,
    // so a tiny max_bytes (256) reads only the LAST ~8 lines.
    var i: usize = 0;
    var content_buf: [16]u8 = undefined;
    while (i < 100) : (i += 1) {
        const content = try std.fmt.bufPrint(&content_buf, "turn-{d:0>3}", .{i});
        _ = appendTurn(testing.allocator, name, .user, content);
    }

    // With max_bytes=256 against ~38-byte lines, the tail window
    // holds ~6 fully-contained lines. Ask for ALL of them and
    // pin both ends so an off-by-one in the seek offset or an
    // extra-line strip surfaces. The head-reading bug would
    // load turn-000 onwards; the fix loads turn-094 onwards
    // (or thereabouts — exact start depends on where the partial
    // fragment falls in the JSON envelope).
    var loaded = try loadLastTurns(testing.allocator, name, 20, 256);
    defer {
        for (loaded.items) |t| testing.allocator.free(t.content);
        loaded.deinit(testing.allocator);
    }
    // Must end with turn-099 (the actual newest).
    try testing.expect(loaded.items.len > 0);
    try testing.expectEqualStrings(
        "turn-099",
        loaded.items[loaded.items.len - 1].content,
    );
    // First item must be in the high-90s range — the head-bug
    // would put it at turn-000 or turn-001.
    const first = loaded.items[0].content;
    try testing.expect(std.mem.startsWith(u8, first, "turn-09"));
}

test "loadLastTurns: caps at max_turns (keeps newest)" {
    var name_buf: [64]u8 = undefined;
    // Test-fixture uniqueness — pid + ts via clock_gettime. Tests
    // don't run in parallel against the same file; `unlink` clears
    // it below.
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    const seed: u64 = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    const name = try std.fmt.bufPrint(&name_buf, "/tmp/atty-chat-test-{x}.jsonl", .{seed});
    const name_z = try testing.allocator.dupeZ(u8, name);
    defer testing.allocator.free(name_z);
    defer _ = std.c.unlink(name_z.ptr);

    // Write 5 turns, ask for last 3 — should get turns 3, 4, 5 in
    // chronological order.
    _ = appendTurn(testing.allocator, name, .user, "t1");
    _ = appendTurn(testing.allocator, name, .user, "t2");
    _ = appendTurn(testing.allocator, name, .user, "t3");
    _ = appendTurn(testing.allocator, name, .user, "t4");
    _ = appendTurn(testing.allocator, name, .user, "t5");

    var loaded = try loadLastTurns(testing.allocator, name, 3, 1 << 20);
    defer {
        for (loaded.items) |t| testing.allocator.free(t.content);
        loaded.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 3), loaded.items.len);
    try testing.expectEqualStrings("t3", loaded.items[0].content);
    try testing.expectEqualStrings("t4", loaded.items[1].content);
    try testing.expectEqualStrings("t5", loaded.items[2].content);
}

test "rotateIfExceeded: trims to keep_bytes worth of whole lines" {
    var name_buf: [64]u8 = undefined;
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    const seed: u64 = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    const name = try std.fmt.bufPrint(&name_buf, "/tmp/atty-chat-rotate-{x}.jsonl", .{seed});
    const name_z = try testing.allocator.dupeZ(u8, name);
    defer testing.allocator.free(name_z);
    defer _ = std.c.unlink(name_z.ptr);

    // Write 10 turns. Each NDJSON line is roughly 40 bytes
    // (`{"kind":"user","content":"tN"}\n`).
    var i: u8 = 0;
    while (i < 10) : (i += 1) {
        var content_buf: [4]u8 = undefined;
        const c = std.fmt.bufPrint(&content_buf, "t{d:0>2}", .{i}) catch unreachable;
        _ = appendTurn(testing.allocator, name, .user, c);
    }

    // Rotate to keep ~200 bytes — should drop the oldest entries.
    const rotated = rotateIfExceeded(testing.allocator, name, 200);
    try testing.expect(rotated);

    var loaded = try loadLastTurns(testing.allocator, name, 100, 1 << 20);
    defer {
        for (loaded.items) |t| testing.allocator.free(t.content);
        loaded.deinit(testing.allocator);
    }
    // Expect fewer than 10 turns and the newest (t09) to be the
    // last one. The boundary is "first whole line at or after
    // (cur_size - keep_bytes)" — exact count depends on byte
    // layout, so we assert the bound + newest-preserved invariant.
    try testing.expect(loaded.items.len > 0);
    try testing.expect(loaded.items.len < 10);
    try testing.expectEqualStrings("t09", loaded.items[loaded.items.len - 1].content);
}

test "rotateIfExceeded: no-op when file size <= keep_bytes" {
    var name_buf: [64]u8 = undefined;
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    const seed: u64 = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec)) +% 17;
    const name = try std.fmt.bufPrint(&name_buf, "/tmp/atty-chat-rotate-noop-{x}.jsonl", .{seed});
    const name_z = try testing.allocator.dupeZ(u8, name);
    defer testing.allocator.free(name_z);
    defer _ = std.c.unlink(name_z.ptr);

    _ = appendTurn(testing.allocator, name, .user, "short");
    // Cap is generous; nothing to do.
    try testing.expect(!rotateIfExceeded(testing.allocator, name, 1 << 20));
}

test "resolvePath: explicit path is returned verbatim" {
    const path = try resolvePath(testing.allocator, "/tmp/explicit-test.jsonl");
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/tmp/explicit-test.jsonl", path);
}

test "loadLastTurns: skips malformed lines (forward-compat)" {
    var name_buf: [64]u8 = undefined;
    // Test-fixture uniqueness — pid + ts via clock_gettime. Tests
    // don't run in parallel against the same file; `unlink` clears
    // it below.
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    const seed: u64 = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    const name = try std.fmt.bufPrint(&name_buf, "/tmp/atty-chat-test-{x}.jsonl", .{seed});
    const name_z = try testing.allocator.dupeZ(u8, name);
    defer testing.allocator.free(name_z);
    defer _ = std.c.unlink(name_z.ptr);

    // Mix valid + malformed lines; loader should pick up only the
    // valid ones.
    _ = appendTurn(testing.allocator, name, .user, "valid1");
    {
        // Hand-write a bogus line to simulate a future-version format
        // or a corrupted entry.
        const path_z = try testing.allocator.dupeZ(u8, name);
        defer testing.allocator.free(path_z);
        const fd = open(path_z.ptr, O_WRONLY | O_APPEND);
        defer _ = close(fd);
        const garbage = "this is not json\n";
        _ = write(fd, garbage.ptr, garbage.len);
        const future = "{\"kind\":\"future_kind\",\"content\":\"x\"}\n";
        _ = write(fd, future.ptr, future.len);
    }
    _ = appendTurn(testing.allocator, name, .user, "valid2");

    var loaded = try loadLastTurns(testing.allocator, name, 10, 1 << 20);
    defer {
        for (loaded.items) |t| testing.allocator.free(t.content);
        loaded.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 2), loaded.items.len);
    try testing.expectEqualStrings("valid1", loaded.items[0].content);
    try testing.expectEqualStrings("valid2", loaded.items[1].content);
}
