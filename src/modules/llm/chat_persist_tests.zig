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
const appendConclusion = mod.appendConclusion;
const LoadedTurn = mod.LoadedTurn;
const loadLastTurns = mod.loadLastTurns;
const parseLine = mod.parseLine;
const resolveDir = mod.resolveDir;
const createSessionPath = mod.createSessionPath;

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
    // Assert each append succeeds so a disk-full or permission
    // failure can't make the test pass against a partial file.
    var i: usize = 0;
    var content_buf: [16]u8 = undefined;
    while (i < 100) : (i += 1) {
        const content = try std.fmt.bufPrint(&content_buf, "turn-{d:0>3}", .{i});
        try testing.expect(appendTurn(testing.allocator, name, .user, content));
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

test "loadLastTurns: seek landing on line boundary keeps the first tail line" {
    // Regression for the partial-line-skip false-positive: if
    // the seek to `size - max_bytes` happens to land exactly
    // at a `\n`-followed offset, the read window starts at a
    // COMPLETE line and the "drop fragment" logic must NOT
    // discard it. We craft the file so size - max_bytes lands
    // exactly one byte after a `\n`.
    var name_buf: [80]u8 = undefined;
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    const seed: u64 = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    const name = try std.fmt.bufPrint(&name_buf, "/tmp/atty-chat-boundary-{x}.jsonl", .{seed});
    const name_z = try testing.allocator.dupeZ(u8, name);
    defer testing.allocator.free(name_z);
    defer _ = std.c.unlink(name_z.ptr);

    // Build a file shaped so we can compute the exact boundary.
    // Padding line = 100 bytes (99 X + \n at byte 99). Then two
    // tail lines exactly 36 bytes each = 72 bytes. Total = 172
    // bytes. max_bytes = 72 → seek offset = 172 - 72 = 100.
    // Byte 99 is the padding's `\n`, byte 100 starts the first
    // JSON line — boundary case.
    const fd = open(name_z.ptr, O_WRONLY | O_CREAT, @as(c_uint, 0o600));
    try testing.expect(fd >= 0);
    var pad: [100]u8 = undefined;
    @memset(&pad, 'X');
    pad[99] = '\n';
    _ = write(fd, &pad, pad.len);
    // Two minimal-shape JSON turns padded with whitespace in
    // the content to make each line exactly 36 bytes (including
    // the trailing `\n`).
    const line1 = "{\"kind\":\"user\",\"content\":\"first  \"}\n";
    const line2 = "{\"kind\":\"user\",\"content\":\"second \"}\n";
    try testing.expectEqual(@as(usize, 36), line1.len);
    try testing.expectEqual(@as(usize, 36), line2.len);
    _ = write(fd, line1.ptr, line1.len);
    _ = write(fd, line2.ptr, line2.len);
    _ = close(fd);
    // File size: 100 + 36 + 36 = 172. max_bytes = 72 → seek
    // offset = 100. Byte 99 is `\n` → boundary.
    var loaded = try loadLastTurns(testing.allocator, name, 5, 72);
    defer {
        for (loaded.items) |t| testing.allocator.free(t.content);
        loaded.deinit(testing.allocator);
    }
    // Both tail lines must be present (not just the second one).
    try testing.expectEqual(@as(usize, 2), loaded.items.len);
    try testing.expectEqualStrings("first  ", loaded.items[0].content);
    try testing.expectEqualStrings("second ", loaded.items[1].content);
}

test "loadLastTurns: oversized single line with no trailing newline still parses" {
    // The seek-path's fall-through-when-no-\n branch is only
    // exercisable with a manually-constructed file (appendTurn
    // always writes \n). Build a file with garbage padding +
    // one valid JSON line at the tail, NO trailing \n. With
    // max_bytes sized to seek INTO the JSON line's start byte,
    // the partial-line skip would normally bail; the fall-
    // through must instead parse the whole window as one line.
    var name_buf: [80]u8 = undefined;
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    const seed: u64 = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    const name = try std.fmt.bufPrint(&name_buf, "/tmp/atty-chat-fallthrough-{x}.jsonl", .{seed});
    const name_z = try testing.allocator.dupeZ(u8, name);
    defer testing.allocator.free(name_z);
    defer _ = std.c.unlink(name_z.ptr);

    // 600 bytes of padding (one long "old" line + \n) followed
    // by 40 bytes of NDJSON without trailing newline. max_bytes
    // = 50 → seek to size - 50 lands inside the padding, the
    // partial-line skip discards up to the \n at the start of
    // the JSON line. After the skip, the window is the 40-byte
    // JSON line WITH no trailing \n — exactly the fall-through
    // case.
    const fd = open(name_z.ptr, O_WRONLY | O_CREAT, @as(c_uint, 0o600));
    try testing.expect(fd >= 0);
    var pad: [600]u8 = undefined;
    @memset(&pad, 'X');
    pad[599] = '\n'; // line terminator for the padding "line"
    _ = write(fd, &pad, pad.len);
    const tail = "{\"kind\":\"user\",\"content\":\"final\"}";
    _ = write(fd, tail.ptr, tail.len);
    _ = close(fd);

    var loaded = try loadLastTurns(testing.allocator, name, 5, 50);
    defer {
        for (loaded.items) |t| testing.allocator.free(t.content);
        loaded.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 1), loaded.items.len);
    try testing.expectEqualStrings("final", loaded.items[0].content);
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

test "appendConclusion: lands AFTER appendTurn (tail position pinned)" {
    var name_buf: [64]u8 = undefined;
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    const seed: u64 = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    const name = try std.fmt.bufPrint(&name_buf, "/tmp/atty-chat-conclude-{x}.jsonl", .{seed});
    const name_z = try testing.allocator.dupeZ(u8, name);
    defer testing.allocator.free(name_z);
    defer _ = std.c.unlink(name_z.ptr);

    try testing.expect(appendTurn(testing.allocator, name, .user, "list zig files"));
    try testing.expect(appendConclusion(testing.allocator, name, "Listed 2 zig files."));

    const fd = std.c.open(name_z.ptr, .{ .ACCMODE = .RDONLY });
    try testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    var buf: [512]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    try testing.expect(n > 0);
    const slice = buf[0..@as(usize, @intCast(n))];
    // Pin ORDER, not just presence: user record must precede the
    // conclusion record (the conclusion appends — never inserts).
    const user_at = std.mem.indexOf(u8, slice, "\"kind\":\"user\"") orelse return error.UserRecordMissing;
    const concl_at = std.mem.indexOf(u8, slice, "\"kind\":\"conclusion\"") orelse return error.ConclusionMissing;
    try testing.expect(user_at < concl_at);
    try testing.expect(std.mem.indexOf(u8, slice, "Listed 2 zig files.") != null);
}

test "resolveDir: explicit dir is returned verbatim AND mkdir-p actually ran" {
    var name_buf: [64]u8 = undefined;
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    const seed: u64 = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    const dir = try std.fmt.bufPrint(&name_buf, "/tmp/atty-resolveDir-{x}", .{seed});

    const got = try resolveDir(testing.allocator, dir);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(dir, got);

    // Cleanup; rmdir returns 0 ONLY when the dir actually exists and
    // is empty — pins that resolveDir performed the mkdir.
    const z = try testing.allocator.dupeZ(u8, dir);
    defer testing.allocator.free(z);
    try testing.expectEqual(@as(c_int, 0), std.c.rmdir(z.ptr));
}

test "resolveDir: missing-and-uncreatable dir surfaces an error" {
    // Try to create a subdir under a non-traversable path. /proc/1
    // exists but is owned by root + non-traversable to regular users;
    // mkdir under it fails EACCES, the final stat fails ENOENT, and
    // resolveDir must surface that — silent success here is what the
    // High finding caught.
    const got = resolveDir(testing.allocator, "/proc/1/atty-cannot-create");
    try testing.expectError(error.PersistenceDirUnavailable, got);
}

test "createSessionPath: timestamp + suffix shape AND reserves the file via O_EXCL" {
    var name_buf: [64]u8 = undefined;
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    const seed: u64 = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    const dir = try std.fmt.bufPrint(&name_buf, "/tmp/atty-create-sess-{x}", .{seed});
    const dir_z = try testing.allocator.dupeZ(u8, dir);
    defer testing.allocator.free(dir_z);
    try testing.expectEqual(@as(c_int, 0), std.c.mkdir(dir_z.ptr, 0o700));
    defer _ = std.c.rmdir(dir_z.ptr);

    const path = try createSessionPath(testing.allocator, dir);
    defer testing.allocator.free(path);
    const path_z = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(path_z);
    defer _ = std.c.unlink(path_z.ptr);

    try testing.expect(std.mem.startsWith(u8, path, dir));
    try testing.expect(std.mem.endsWith(u8, path, ".jsonl"));
    const stem_start = dir.len + 1;
    const stem_end = path.len - ".jsonl".len;
    const stem = path[stem_start..stem_end];
    // YYYYMMDDTHHMMSS = 15 chars, '-' = 1, 6 hex chars = 6 → 22.
    try testing.expectEqual(@as(usize, 22), stem.len);
    try testing.expectEqual(@as(u8, 'T'), stem[8]);
    try testing.expectEqual(@as(u8, '-'), stem[15]);

    // The file MUST exist on disk: createSessionPath's contract is
    // atomic reservation via O_EXCL, not just path-string generation.
    const verify_fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDONLY });
    try testing.expect(verify_fd >= 0);
    _ = std.c.close(verify_fd);
}

test "createSessionPath: two back-to-back calls produce distinct paths (no overwrite)" {
    var name_buf: [64]u8 = undefined;
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    const seed: u64 = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    const dir = try std.fmt.bufPrint(&name_buf, "/tmp/atty-create-sess-distinct-{x}", .{seed});
    const dir_z = try testing.allocator.dupeZ(u8, dir);
    defer testing.allocator.free(dir_z);
    try testing.expectEqual(@as(c_int, 0), std.c.mkdir(dir_z.ptr, 0o700));
    defer _ = std.c.rmdir(dir_z.ptr);

    const a = try createSessionPath(testing.allocator, dir);
    defer testing.allocator.free(a);
    const az = try testing.allocator.dupeZ(u8, a);
    defer testing.allocator.free(az);
    defer _ = std.c.unlink(az.ptr);

    const b = try createSessionPath(testing.allocator, dir);
    defer testing.allocator.free(b);
    const bz = try testing.allocator.dupeZ(u8, b);
    defer testing.allocator.free(bz);
    defer _ = std.c.unlink(bz.ptr);

    try testing.expect(!std.mem.eql(u8, a, b));
}

test "createSessionPath: empty dir returns empty path (no file created)" {
    const path = try createSessionPath(testing.allocator, "");
    defer testing.allocator.free(path);
    try testing.expectEqual(@as(usize, 0), path.len);
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
