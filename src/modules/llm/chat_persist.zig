//! Chat-history persistence — NDJSON load/append.
//!
//! When `cfg.chat_persist_path` is set, atty loads the last N turns
//! from the file at attach AND appends every new turn to it. The
//! file format is one JSON object per line:
//!
//!     {"kind":"user","content":"list zig files"}
//!     {"kind":"assistant_exec","content":"{...}"}
//!     {"kind":"observation","content":"main.zig\nbuild.zig"}
//!
//! Two design choices worth flagging:
//!
//! 1. **Append-only with no rotation.** Atty doesn't try to cap the
//!    file. The user is responsible for managing growth (logrotate,
//!    periodic truncation, a separate per-session file). Atty only
//!    reads the tail at startup, so a multi-GB file is fine at
//!    runtime — just slow to attach.
//!
//! 2. **No content escaping beyond what JSON requires.** Atty uses
//!    `std.json.Stringify.encodeJsonString` on write and the standard
//!    parser on read. Multi-line content (assistant envelopes,
//!    observation output) round-trips through the JSON string
//!    encoding cleanly.

const std = @import("std");

const dialog = @import("dialog.zig");

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn lseek(fd: c_int, offset: i64, whence: c_int) i64;

const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0o100;
const O_APPEND: c_int = 0o2000;
const FILE_MODE: c_int = 0o600;

/// Append one turn to the file as a single NDJSON line. Best-effort:
/// errors are swallowed (callers in the hot pushTurn path don't want
/// to fail a turn-push because the disk is full). Returns true on
/// success so callers can log when they care.
pub fn appendTurn(allocator: std.mem.Allocator, path: []const u8, kind: dialog.TurnKind, content: []const u8) bool {
    if (path.len == 0) return false;
    const path_z = allocator.dupeZ(u8, path) catch return false;
    defer allocator.free(path_z);

    const fd = open(path_z.ptr, O_WRONLY | O_CREAT | O_APPEND, FILE_MODE);
    if (fd < 0) return false;
    defer _ = close(fd);

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    const kind_str: []const u8 = switch (kind) {
        .user => "user",
        .assistant_exec => "assistant_exec",
        .observation => "observation",
    };
    w.writeAll("{\"kind\":\"") catch return false;
    w.writeAll(kind_str) catch return false;
    w.writeAll("\",\"content\":") catch return false;
    std.json.Stringify.encodeJsonString(content, .{}, w) catch return false;
    w.writeAll("}\n") catch return false;

    const bytes = buf.written();
    const n = write(fd, bytes.ptr, bytes.len);
    return n == @as(isize, @intCast(bytes.len));
}

/// Load the LAST `max_turns` turns from `path`. Returns the turns
/// in original order (oldest first) so the caller can pushTurn them
/// directly. Caller owns each returned slice + the outer ArrayList
/// (allocated via `allocator`). Returns an empty list when the file
/// is missing / unreadable / empty.
///
/// Implementation: read the whole file (capped at `max_bytes` to
/// avoid pathological growth), split into lines from the END,
/// reverse-walk taking the last N parseable lines, then re-reverse
/// the result.
pub fn loadLastTurns(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_turns: usize,
    max_bytes: usize,
) !std.ArrayList(LoadedTurn) {
    var result: std.ArrayList(LoadedTurn) = .empty;
    errdefer {
        for (result.items) |t| allocator.free(t.content);
        result.deinit(allocator);
    }
    if (path.len == 0) return result;
    if (max_turns == 0) return result;

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fd = open(path_z.ptr, O_RDONLY);
    if (fd < 0) return result; // missing / unreadable → no history
    defer _ = close(fd);

    // Read in chunks until EOF or cap. Conservative because the
    // file may have grown unboundedly.
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    var chunk: [16 * 1024]u8 = undefined;
    while (raw.items.len < max_bytes) {
        const want: usize = @min(chunk.len, max_bytes - raw.items.len);
        const got = read(fd, &chunk, want);
        if (got <= 0) break;
        try raw.appendSlice(allocator, chunk[0..@as(usize, @intCast(got))]);
    }
    if (raw.items.len == 0) return result;

    // Walk newest → oldest (reverse over LF-delimited lines),
    // collect up to max_turns parseable entries, then reverse.
    var line_starts: std.ArrayList(usize) = .empty;
    defer line_starts.deinit(allocator);
    var i: usize = 0;
    try line_starts.append(allocator, 0);
    while (i < raw.items.len) : (i += 1) {
        if (raw.items[i] == '\n' and i + 1 < raw.items.len) {
            try line_starts.append(allocator, i + 1);
        }
    }

    var idx: usize = line_starts.items.len;
    var taken: usize = 0;
    while (idx > 0 and taken < max_turns) {
        idx -= 1;
        const start = line_starts.items[idx];
        // End is either the next line start or end of buffer
        // (sans trailing \n).
        const end_excl: usize = if (idx + 1 < line_starts.items.len)
            line_starts.items[idx + 1] - 1
        else
            raw.items.len;
        if (end_excl <= start) continue;
        const line = raw.items[start..end_excl];
        const trimmed = std.mem.trimEnd(u8, line, "\r\n");
        if (trimmed.len == 0) continue;
        const parsed = parseLine(allocator, trimmed) catch continue;
        try result.append(allocator, parsed);
        taken += 1;
    }

    // Reverse in place so caller gets oldest-first.
    var lo: usize = 0;
    var hi: usize = result.items.len;
    while (lo + 1 < hi) {
        hi -= 1;
        const tmp = result.items[lo];
        result.items[lo] = result.items[hi];
        result.items[hi] = tmp;
        lo += 1;
    }
    return result;
}

pub const LoadedTurn = struct {
    kind: dialog.TurnKind,
    content: []u8, // owned by caller; allocated via the loader's allocator
};

fn parseLine(allocator: std.mem.Allocator, line: []const u8) !LoadedTurn {
    const Wire = struct {
        kind: []const u8,
        content: []const u8,
    };
    const parsed = try std.json.parseFromSlice(Wire, allocator, line, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const k: dialog.TurnKind = if (std.mem.eql(u8, parsed.value.kind, "user"))
        .user
    else if (std.mem.eql(u8, parsed.value.kind, "assistant_exec"))
        .assistant_exec
    else if (std.mem.eql(u8, parsed.value.kind, "observation"))
        .observation
    else
        return error.UnknownTurnKind;

    const content = try allocator.dupe(u8, parsed.value.content);
    return .{ .kind = k, .content = content };
}

// ─── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

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
