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
//!
//! 3. **`rt.session_id` is intentionally NOT persisted.** Native
//!    CLI session continuation (`--resume <id>`) is per-process —
//!    the CLI may garbage-collect ids between atty runs, and a
//!    stale id from a prior session would either error or resume
//!    state the user doesn't remember. Restart begins a fresh CLI
//!    session even though the chat ring loads prior turns.

const std = @import("std");

const dialog = @import("dialog.zig");

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn lseek(fd: c_int, offset: i64, whence: c_int) i64;
extern "c" fn rename(old_path: [*:0]const u8, new_path: [*:0]const u8) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn fstat(fd: c_int, statbuf: *Stat) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0o100;
const O_APPEND: c_int = 0o2000;
const FILE_MODE: c_int = 0o600;
const DIR_MODE: c_uint = 0o700;

// Minimal stat struct — we only need st_size. Layout matches Linux's
// `struct stat` (the kernel definition; libc passes it through). On
// non-Linux this would need to be revisited; atty is Linux-only.
const Stat = extern struct {
    _pad: [48]u8,
    size: i64,
    _pad2: [80]u8,
};

/// Resolve the persistence file path. Returns owned memory.
///
///   • `explicit_path` non-empty → use verbatim (no tilde expansion).
///   • `explicit_path` empty → derive `${XDG_DATA_HOME}/atty/chat.jsonl`,
///     falling back to `${HOME}/.local/share/atty/chat.jsonl`. Creates
///     the parent directory (mode 0700) so the first append succeeds.
///
/// Returns an empty slice when neither XDG_DATA_HOME nor HOME is set.
pub fn resolvePath(allocator: std.mem.Allocator, explicit_path: []const u8) ![]u8 {
    if (explicit_path.len > 0) return allocator.dupe(u8, explicit_path);

    const xdg = blk: {
        const p = getenv("XDG_DATA_HOME") orelse break :blk null;
        const s = std.mem.span(p);
        if (s.len == 0) break :blk null;
        break :blk s;
    };
    var dir_buf: std.Io.Writer.Allocating = .init(allocator);
    defer dir_buf.deinit();
    if (xdg) |x| {
        try dir_buf.writer.print("{s}/atty", .{x});
    } else {
        const home_p = getenv("HOME") orelse return allocator.dupe(u8, "");
        const home = std.mem.span(home_p);
        if (home.len == 0) return allocator.dupe(u8, "");
        try dir_buf.writer.print("{s}/.local/share/atty", .{home});
    }
    const dir = dir_buf.written();

    // Create the directory tree (idempotent; ignore EEXIST).
    const dir_z = try allocator.dupeZ(u8, dir);
    defer allocator.free(dir_z);
    _ = mkdir(dir_z.ptr, DIR_MODE);

    return std.fmt.allocPrint(allocator, "{s}/chat.jsonl", .{dir});
}

/// Truncate the persistence file to its newest content, keeping at
/// most `keep_bytes` worth of full NDJSON lines. Atomic via
/// tmp+rename so a crash mid-rotation can't corrupt the file.
/// Caller invokes BEFORE appending the next line.
///
/// Best-effort: any error (file missing, rename fails) is swallowed
/// — the worst case is the file growing past the cap for another
/// turn until the next call. Returns true when rotation actually
/// ran (file exceeded the cap AND truncation succeeded).
pub fn rotateIfExceeded(allocator: std.mem.Allocator, path: []const u8, keep_bytes: usize) bool {
    if (path.len == 0 or keep_bytes == 0) return false;
    const path_z = allocator.dupeZ(u8, path) catch return false;
    defer allocator.free(path_z);

    // Check current size — open + fstat.
    const fd_r = open(path_z.ptr, O_RDONLY);
    if (fd_r < 0) return false;
    var st: Stat = undefined;
    if (fstat(fd_r, &st) != 0) {
        _ = close(fd_r);
        return false;
    }
    const cur_size: usize = if (st.size > 0) @intCast(st.size) else 0;
    if (cur_size <= keep_bytes) {
        _ = close(fd_r);
        return false;
    }

    // Seek to the keep window, read forward to find the first \n
    // (so we keep WHOLE lines), then read the rest into memory and
    // rewrite the file.
    const start_off: i64 = @intCast(cur_size - keep_bytes);
    _ = lseek(fd_r, start_off, 0); // SEEK_SET = 0
    var tail: std.ArrayList(u8) = .empty;
    defer tail.deinit(allocator);
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const got = read(fd_r, &chunk, chunk.len);
        if (got <= 0) break;
        tail.appendSlice(allocator, chunk[0..@as(usize, @intCast(got))]) catch {
            _ = close(fd_r);
            return false;
        };
    }
    _ = close(fd_r);

    // Drop everything up to the first \n to ensure we start at a
    // full-line boundary.
    const trim_at = std.mem.indexOfScalar(u8, tail.items, '\n');
    const kept: []const u8 = if (trim_at) |i| tail.items[i + 1 ..] else &.{};

    // Atomic rewrite: write to tmp, fsync (best-effort), rename.
    const tmp_path = std.fmt.allocPrint(allocator, "{s}.atty-tmp", .{path}) catch return false;
    defer allocator.free(tmp_path);
    const tmp_z = allocator.dupeZ(u8, tmp_path) catch return false;
    defer allocator.free(tmp_z);
    const fd_w = open(tmp_z.ptr, O_WRONLY | O_CREAT | 0o1000, FILE_MODE); // 0o1000 = O_TRUNC
    if (fd_w < 0) return false;
    const wn = write(fd_w, kept.ptr, kept.len);
    _ = close(fd_w);
    if (wn != @as(isize, @intCast(kept.len))) return false;
    return rename(tmp_z.ptr, path_z.ptr) == 0;
}

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
/// Implementation: when the file is larger than `max_bytes`, seek
/// to `size - max_bytes` and discard the (necessarily-partial)
/// first line — that gives a clean tail window onto the newest
/// content. Then split into lines, reverse-walk taking the last N
/// parseable entries, and re-reverse so the caller sees them in
/// chronological order.
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

    // For files larger than the cap, seek to size - max_bytes
    // so we read the TAIL — the most recent turns. The previous
    // implementation read from offset 0, which for >max_bytes
    // files restored the oldest turns from the first chunk
    // instead of the newest. `fstat` returns size; lseek + skip
    // the partial first line gives a clean window onto the tail.
    //
    // On fstat/lseek failure for a known-oversized file, RETURN
    // EMPTY rather than falling through to the head-read path.
    // The head-read is exactly the bug we're fixing; silently
    // re-introducing it on a syscall failure would be a worse
    // failure mode than "no history loaded".
    var stat: Stat = undefined;
    var skip_partial_line = false;
    if (fstat(fd, &stat) == 0) {
        const size: u64 = if (stat.size > 0) @intCast(stat.size) else 0;
        if (size > max_bytes) {
            const off: i64 = @intCast(size - max_bytes);
            if (lseek(fd, off, 0) >= 0) {
                // SEEK_SET landed inside an arbitrary line; the
                // bytes before the next \n are a fragment.
                // Discarding them avoids a parseLine failure on
                // the truncated head (and the bytes are duplicated
                // in older history we're intentionally dropping).
                skip_partial_line = true;
            } else {
                // fstat said the file is too big but lseek failed
                // — refuse the head-read fallback.
                return result;
            }
        }
    }
    // Note: fstat itself failing is treated as "unknown size,
    // probably small" — keep reading from offset 0 like the
    // original behavior. Small files don't exhibit the bug.

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

    if (skip_partial_line) {
        if (std.mem.indexOfScalar(u8, raw.items, '\n')) |nl| {
            // Drop everything up to and including the first \n —
            // that's the truncated fragment plus its terminator.
            const drop_n = nl + 1;
            const remaining = raw.items.len - drop_n;
            std.mem.copyForwards(u8, raw.items[0..remaining], raw.items[drop_n..]);
            raw.shrinkRetainingCapacity(remaining);
        } else {
            // No newline in the read window — the entire window
            // is a single overlong line; nothing parseable.
            return result;
        }
    }

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

pub fn parseLine(allocator: std.mem.Allocator, line: []const u8) !LoadedTurn {
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

// ===========================================================================
// Tests — extracted to `chat_persist_tests.zig` for readability.
// ===========================================================================

test {
    _ = @import("chat_persist_tests.zig");
}
