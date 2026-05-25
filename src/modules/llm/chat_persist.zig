//! Chat-history persistence — NDJSON, one file per dialog session.
//!
//! Each atty session that opens a chat surface gets its own
//! timestamped file under `${XDG_STATE_HOME:-~/.local/state}/atty/
//! dialogs/`. Every `pushTurn` appends one JSON line; on dialog
//! close the conclusion banner is appended as a final record:
//!
//!     {"kind":"user","content":"list zig files"}
//!     {"kind":"assistant_exec","content":"{...}"}
//!     {"kind":"observation","content":"main.zig\nbuild.zig"}
//!     {"kind":"conclusion","content":"Listed 2 zig files."}
//!
//! Design choices:
//!
//! 1. **One file per session.** A picker (future PR) needs distinct
//!    artifacts to surface; rolling-history-in-one-file foreclosed
//!    that UX. Per-file means O(N) directory entries — see the
//!    retention sweep on the picker side.
//!
//! 2. **No content escaping beyond what JSON requires.** Write via
//!    `std.json.Stringify.encodeJsonString`, read via the standard
//!    parser. Multi-line content round-trips cleanly.
//!
//! 3. **`rt.session_id` (provider-side) is intentionally NOT
//!    persisted.** Provider CLIs garbage-collect ids between runs;
//!    a stale id would error or resume state the user doesn't
//!    remember. Restart begins a fresh provider session even when
//!    the chat ring loads prior turns.

const std = @import("std");

const dialog = @import("dialog.zig");

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn lseek(fd: c_int, offset: i64, whence: c_int) i64;
extern "c" fn pread(fd: c_int, buf: [*]u8, count: usize, offset: i64) isize;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn fstat(fd: c_int, statbuf: *Stat) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
extern "c" fn getpid() c_int;
extern "c" fn clock_gettime(clk_id: c_int, tp: *std.posix.timespec) c_int;
const CLOCK_REALTIME: c_int = 0;
const O_EXCL: c_int = 0o200;
const O_DIRECTORY: c_int = 0o200000;

const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0o100;
const O_APPEND: c_int = 0o2000;
const FILE_MODE: c_int = 0o600;
const DIR_MODE: c_uint = 0o700;

// glibc x86_64 `struct stat` — we only need `size` for
// `loadLastTurns`'s tail seek. The 48-byte pad matches the
// offset of `st_size` in this libc/arch combo. Dir validation
// uses `open(O_RDONLY|O_DIRECTORY)` instead of stat to dodge
// the per-arch layout drift entirely (mode lives at a
// different offset on aarch64 vs x86_64).
const Stat = extern struct {
    _pad: [48]u8,
    size: i64,
    _pad2: [80]u8,
};

/// Resolve the dialogs directory. Returns owned memory; creates
/// the directory tree on disk (mode 0700) so later opens succeed.
///
///   • `explicit_dir` non-empty → use verbatim (no tilde expansion).
///   • `explicit_dir` empty → derive `${XDG_STATE_HOME}/atty/dialogs`,
///     falling back to `${HOME}/.local/state/atty/dialogs`.
///
/// Returns an empty slice when neither XDG_STATE_HOME nor HOME is
/// set (caller treats as "persistence unavailable").
pub fn resolveDir(allocator: std.mem.Allocator, explicit_dir: []const u8) ![]u8 {
    var dir_buf: std.Io.Writer.Allocating = .init(allocator);
    defer dir_buf.deinit();

    if (explicit_dir.len > 0) {
        try dir_buf.writer.writeAll(explicit_dir);
    } else {
        const xdg = blk: {
            const p = getenv("XDG_STATE_HOME") orelse break :blk null;
            const s = std.mem.span(p);
            if (s.len == 0) break :blk null;
            break :blk s;
        };
        if (xdg) |x| {
            try dir_buf.writer.print("{s}/atty/dialogs", .{x});
        } else {
            const home_p = getenv("HOME") orelse return allocator.dupe(u8, "");
            const home = std.mem.span(home_p);
            if (home.len == 0) return allocator.dupe(u8, "");
            try dir_buf.writer.print("{s}/.local/state/atty/dialogs", .{home});
        }
    }
    const dir = dir_buf.written();

    // mkdir -p the path one segment at a time so the parents exist.
    // Single-pass (no per-segment retry on EEXIST): a fresh mkdir
    // failing for any reason other than "already exists" surfaces
    // via the final stat check below.
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i == dir.len or dir[i] == '/') {
            const seg = try allocator.dupeZ(u8, dir[0..i]);
            defer allocator.free(seg);
            _ = mkdir(seg.ptr, DIR_MODE);
        }
    }

    // Verify the final segment actually exists AND is a directory.
    // Probing via open(O_DIRECTORY) instead of stat() because the
    // `struct stat` layout drifts across libc + arch combos (mode
    // at offset 24 on x86_64, offset 16 on aarch64-musl), and we
    // don't want a release binary to silently mis-decode the type
    // bits and disable persistence. O_DIRECTORY's contract is
    // kernel-level: success ↔ path is a directory; ENOTDIR ↔ not
    // a dir; ENOENT / EACCES ↔ doesn't exist or unreachable.
    const dir_z = try allocator.dupeZ(u8, dir);
    defer allocator.free(dir_z);
    const probe = open(dir_z.ptr, O_RDONLY | O_DIRECTORY);
    if (probe < 0) return error.PersistenceDirUnavailable;
    _ = close(probe);

    return allocator.dupe(u8, dir);
}

/// Reserve a fresh per-session file path inside `dir` by
/// creating an empty file with `O_CREAT|O_EXCL`. Format:
/// `<dir>/YYYYMMDDTHHMMSS-<suffix>.jsonl`. The suffix mixes
/// nanoseconds with pid for an initial guess, then retries
/// (up to 64 times) on EEXIST by tweaking the suffix — that
/// closes the two-atty-processes-collide-on-(ns,pid) window
/// completely. Trade-off: every session leaves an artifact on
/// disk, even ones that never push a turn. Worth it for the
/// no-overwrite guarantee.
pub fn createSessionPath(allocator: std.mem.Allocator, dir: []const u8) ![]u8 {
    if (dir.len == 0) return allocator.dupe(u8, "");
    var ts: std.posix.timespec = undefined;
    _ = clock_gettime(CLOCK_REALTIME, &ts);
    const epoch_secs: u64 = if (ts.sec > 0) @intCast(ts.sec) else 0;
    const ep = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const yd = ep.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = ep.getDaySeconds();
    const ns: u64 = if (ts.nsec > 0) @intCast(ts.nsec) else 0;
    const pid: u32 = @bitCast(getpid());

    var attempt: u32 = 0;
    while (attempt < 64) : (attempt += 1) {
        const mix: u32 = @as(u32, @truncate(ns)) ^ pid ^ attempt;
        const r0: u8 = @truncate(mix >> 16);
        const r1: u8 = @truncate(mix >> 8);
        const r2: u8 = @truncate(mix);
        const candidate = try std.fmt.allocPrint(
            allocator,
            "{s}/{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}-{x:0>2}{x:0>2}{x:0>2}.jsonl",
            .{
                dir,
                @as(u16, yd.year),
                md.month.numeric(),
                md.day_index + 1,
                ds.getHoursIntoDay(),
                ds.getMinutesIntoHour(),
                ds.getSecondsIntoMinute(),
                r0,
                r1,
                r2,
            },
        );
        errdefer allocator.free(candidate);

        const cz = try allocator.dupeZ(u8, candidate);
        defer allocator.free(cz);
        const fd = open(cz.ptr, O_WRONLY | O_CREAT | O_EXCL, FILE_MODE);
        if (fd >= 0) {
            _ = close(fd);
            return candidate;
        }
        // open failed — most likely EEXIST. Free this attempt and
        // try the next suffix.
        allocator.free(candidate);
    }
    return error.PersistencePathCollision;
}

/// Append one turn to the file as a single NDJSON line. Best-effort:
/// errors are swallowed (callers in the hot pushTurn path don't want
/// to fail a turn-push because the disk is full). Returns true on
/// success so callers can log when they care.
pub fn appendTurn(allocator: std.mem.Allocator, path: []const u8, kind: dialog.TurnKind, content: []const u8) bool {
    if (path.len == 0) return false;
    return appendRecord(allocator, path, turnKindStr(kind), content);
}

/// Append a final `kind:"conclusion"` record. Called once per dialog
/// when the conclusion banner has been captured. Same best-effort
/// semantics as appendTurn.
pub fn appendConclusion(allocator: std.mem.Allocator, path: []const u8, text: []const u8) bool {
    if (path.len == 0) return false;
    return appendRecord(allocator, path, "conclusion", text);
}

fn appendRecord(allocator: std.mem.Allocator, path: []const u8, kind_str: []const u8, content: []const u8) bool {
    const path_z = allocator.dupeZ(u8, path) catch return false;
    defer allocator.free(path_z);

    const fd = open(path_z.ptr, O_WRONLY | O_CREAT | O_APPEND, FILE_MODE);
    if (fd < 0) return false;
    defer _ = close(fd);

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    w.writeAll("{\"kind\":\"") catch return false;
    w.writeAll(kind_str) catch return false;
    w.writeAll("\",\"content\":") catch return false;
    std.json.Stringify.encodeJsonString(content, .{}, w) catch return false;
    w.writeAll("}\n") catch return false;

    const bytes = buf.written();
    const n = write(fd, bytes.ptr, bytes.len);
    return n == @as(isize, @intCast(bytes.len));
}

fn turnKindStr(kind: dialog.TurnKind) []const u8 {
    return switch (kind) {
        .user => "user",
        .assistant_exec => "assistant_exec",
        .observation => "observation",
    };
}

/// Load the LAST `max_turns` turns from `path`. Returns the turns
/// in original order (oldest first) so the caller can pushTurn them
/// directly. Caller owns each returned slice + the outer ArrayList
/// (allocated via `allocator`). Returns an empty list when the file
/// is missing / unreadable / empty.
///
/// Reserved for the recall picker landing in a follow-up PR — no
/// production caller invokes this in the per-dialog-file design.
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
    var st_info: Stat = undefined;
    var skip_partial_line = false;
    if (fstat(fd, &st_info) == 0) {
        const size: u64 = if (st_info.size > 0) @intCast(st_info.size) else 0;
        if (size > max_bytes) {
            const off: i64 = @intCast(size - max_bytes);
            // Peek the byte at `off - 1` to detect whether the
            // seek landed exactly at a line boundary. If the
            // previous byte is `\n`, the read window starts at
            // a complete line — dropping the "partial" first
            // line would actually drop a VALID turn. Only set
            // skip when we definitely landed mid-line.
            var prev_byte: [1]u8 = undefined;
            const peek_off: i64 = off - 1;
            const peeked = pread(fd, &prev_byte, 1, peek_off);
            const lands_on_boundary = peeked == 1 and prev_byte[0] == '\n';
            if (lseek(fd, off, 0) >= 0) {
                skip_partial_line = !lands_on_boundary;
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
        }
        // No newline in the read window means one of two things:
        //   (a) the seek landed at the start of a line and the
        //       file's last line has no trailing \n;
        //   (b) a single JSON line is longer than `max_bytes`.
        // Either way, fall through to the parse loop below — if
        // the buffer parses as a single valid line we keep it;
        // if not, we return empty as before. The fall-through is
        // cheap and the only path that gains a valid turn from it.
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
