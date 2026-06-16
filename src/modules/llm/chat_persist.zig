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
//! 3. **`rt.session_id` (provider-side) IS persisted** as a
//!    `kind:"session_id"` record so a recalled dialog can resume
//!    the provider session via `--resume <id>` instead of starting
//!    fresh. Provider CLIs garbage-collect ids over time; a stale
//!    id will surface as a provider-side error on the next request
//!    and the user can press Alt+r to retry (which the soft-reset
//!    path treats like any other transient failure).

const std = @import("std");

const dialog = @import("dialog.zig");

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn lseek(fd: c_int, offset: i64, whence: c_int) i64;
extern "c" fn pread(fd: c_int, buf: [*]u8, count: usize, offset: i64) isize;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
extern "c" fn getpid() c_int;
// open(2) flags derived from std.posix.O so the bit positions are
// OS-correct (Darwin/BSD differ from Linux) instead of hardcoded Linux
// octals. clock_gettime uses std.c so the clockid_t is OS-correct too.
const O_EXCL: c_int = @bitCast(std.posix.O{ .EXCL = true });
const O_DIRECTORY: c_int = @bitCast(std.posix.O{ .DIRECTORY = true });
const O_RDONLY: c_int = @bitCast(std.posix.O{ .ACCMODE = .RDONLY });
const O_WRONLY: c_int = @bitCast(std.posix.O{ .ACCMODE = .WRONLY });
const O_CREAT: c_int = @bitCast(std.posix.O{ .CREAT = true });
const O_APPEND: c_int = @bitCast(std.posix.O{ .APPEND = true });
const FILE_MODE: c_int = 0o600;
const DIR_MODE: c_uint = 0o700;

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
        // Normalize to absolute — `listDialogs` uses
        // `openDirAbsolute` which rejects relative paths. A
        // user config supplying e.g. `dialogs/` would otherwise
        // silently fall through to "no dialogs" + retention
        // never running.
        if (explicit_dir[0] == '/') {
            try dir_buf.writer.writeAll(explicit_dir);
        } else {
            const home_p = getenv("HOME") orelse return allocator.dupe(u8, "");
            const home = std.mem.span(home_p);
            if (home.len == 0) return allocator.dupe(u8, "");
            try dir_buf.writer.print("{s}/{s}", .{ home, explicit_dir });
        }
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
    // Zero-init so a (rare) clock_gettime failure yields a best-effort
    // 0 timestamp rather than reading uninitialized fields.
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(.REALTIME, &ts);
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

/// Append a `kind:"session_id"` record so a later recall can
/// re-issue `--resume <id>` instead of starting a fresh provider
/// session. The last `session_id` record wins on load (the worker
/// can produce a fresh id mid-dialog if the provider rotates).
pub fn appendSessionId(allocator: std.mem.Allocator, path: []const u8, id: []const u8) bool {
    if (path.len == 0 or id.len == 0) return false;
    return appendRecord(allocator, path, "session_id", id);
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

/// Best-effort `unlink(2)` on a null-terminated path. Used by the
/// detach + dialog-rotation paths to drop unused 0-byte session
/// reservations. Failures are silent — the only consequence is a
/// stale 0-byte file the user (or PR 2's retention sweep) sweeps later.
pub fn unlinkPath(path_z: [*:0]const u8) c_int {
    return unlink(path_z);
}

/// Open a path read-only. Thin pub wrapper so the recall loader
/// (in hooks.zig) doesn't need its own `extern "c" fn open` decl.
pub fn openReadOnly(path_z: [*:0]const u8) c_int {
    return open(path_z, O_RDONLY);
}

pub fn closeFd(fd: c_int) c_int {
    return close(fd);
}

pub fn readBytes(fd: c_int, buf: [*]u8, count: usize) isize {
    return read(fd, buf, count);
}

/// Load the LAST `max_turns` turns from `path`. Returns the turns
/// in original order (oldest first) so the caller can pushTurn them
/// directly. Caller owns each returned slice + the outer ArrayList
/// (allocated via `allocator`). Returns an empty list when the file
/// is missing / unreadable / empty.
///
/// Used by `loadDialogFromMeta` to hydrate a saved session at chat-
/// open time; the recall picker is the other production caller.
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

    // For files larger than the cap, seek to size - max_bytes so we
    // read the TAIL — the most recent turns. The previous
    // implementation read from offset 0, which for >max_bytes files
    // restored the oldest turns from the first chunk instead of the
    // newest. lseek gives the size + the tail window.
    //
    // On lseek failure for a known-oversized file, RETURN EMPTY rather
    // than falling through to the head-read path. The head-read is
    // exactly the bug we're fixing; silently re-introducing it on a
    // syscall failure would be a worse failure mode than "no history".
    // Probe the size with `lseek(SEEK_END)` instead of a hand-rolled
    // `fstat`+`struct stat`: the latter's `st_size` offset is
    // libc/arch-specific (glibc-x86_64 vs musl/aarch64), which CI's
    // musl builds would misread. `lseek` takes a plain i64 offset — no
    // per-arch layout to get wrong. The probe moves the cursor to EOF,
    // so we MUST seek back to the read offset below.
    const SEEK_SET: c_int = 0;
    const SEEK_END: c_int = 2;
    var skip_partial_line = false;
    var read_off: i64 = 0;
    const size_i = lseek(fd, 0, SEEK_END);
    if (size_i > 0 and @as(u64, @intCast(size_i)) > max_bytes) {
        read_off = @intCast(@as(u64, @intCast(size_i)) - max_bytes);
        // Peek the byte at `read_off - 1` to detect whether the window
        // starts exactly at a line boundary. If the previous byte is
        // `\n`, the first line is complete — dropping it as "partial"
        // would drop a VALID turn. Only skip when we landed mid-line.
        var prev_byte: [1]u8 = undefined;
        const peeked = pread(fd, &prev_byte, 1, read_off - 1);
        skip_partial_line = !(peeked == 1 and prev_byte[0] == '\n');
    }
    // Seek to the read offset (0 for small files — the SEEK_END probe
    // left the cursor at EOF, so the rewind is required even there).
    // Refuse on seek failure rather than re-introducing the head-read
    // bug this tail-seek exists to fix.
    if (lseek(fd, read_off, SEEK_SET) < 0) return result;

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

/// A single record read from a per-session NDJSON file. Either a
/// `Turn` of one of the three modeled kinds, or a `conclusion`
/// banner appended at dialog end. The recall picker uses this to
/// populate both `rt.turns` and `rt.conclusion_formatted` from
/// one parse pass.
pub const LoadedRecord = union(enum) {
    turn: LoadedTurn,
    conclusion: []u8, // owned
    session_id: []u8, // owned

    pub fn deinit(self: LoadedRecord, allocator: std.mem.Allocator) void {
        switch (self) {
            .turn => |t| allocator.free(t.content),
            .conclusion => |c| allocator.free(c),
            .session_id => |s| allocator.free(s),
        }
    }
};

/// Like `parseLine` but also recognises `kind:"conclusion"`. Used by
/// the recall picker's loader; turn-only consumers stay on
/// `parseLine` which still rejects conclusion records with
/// `UnknownTurnKind` (forward-compatible silent skip on the load
/// path).
pub fn parseRecord(allocator: std.mem.Allocator, line: []const u8) !LoadedRecord {
    const Wire = struct {
        kind: []const u8,
        content: []const u8,
    };
    const parsed = try std.json.parseFromSlice(Wire, allocator, line, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (std.mem.eql(u8, parsed.value.kind, "conclusion")) {
        const content = try allocator.dupe(u8, parsed.value.content);
        return .{ .conclusion = content };
    }
    if (std.mem.eql(u8, parsed.value.kind, "session_id")) {
        const content = try allocator.dupe(u8, parsed.value.content);
        return .{ .session_id = content };
    }
    const k: dialog.TurnKind = if (std.mem.eql(u8, parsed.value.kind, "user"))
        .user
    else if (std.mem.eql(u8, parsed.value.kind, "assistant_exec"))
        .assistant_exec
    else if (std.mem.eql(u8, parsed.value.kind, "observation"))
        .observation
    else
        return error.UnknownTurnKind;
    const content = try allocator.dupe(u8, parsed.value.content);
    return .{ .turn = .{ .kind = k, .content = content } };
}

/// Metadata for one persisted dialog file, surfaced to the recall
/// picker. `path` / `name` / `preview` are owned by the caller;
/// `freeDialogMeta` releases them. `preview` is the first user
/// turn's content (truncated, control-byte-stripped) — empty when
/// the file is unreadable, the first record isn't a user turn, or
/// the content is empty.
pub const DialogMeta = struct {
    path: []u8, // owned, absolute
    name: []u8, // owned, basename only (no .jsonl suffix)
    preview: []u8, // owned; may be empty
};

pub fn freeDialogMeta(allocator: std.mem.Allocator, m: DialogMeta) void {
    allocator.free(m.path);
    allocator.free(m.name);
    allocator.free(m.preview);
}

pub fn freeDialogMetaList(allocator: std.mem.Allocator, list: []DialogMeta) void {
    for (list) |m| freeDialogMeta(allocator, m);
    allocator.free(list);
}

/// List dialog files in `dir`, sorted newest-first.
///
/// Only filenames matching the exact `YYYYMMDDTHHMMSS-XXXXXX
/// .jsonl` shape that `createSessionPath` emits are surfaced —
/// stray files (e.g. a hand-pasted `notes.jsonl`) get ignored
/// so the retention sweep never touches them. "Newest" =
/// basename lexical descending, which equals chronological
/// order for the timestamp-prefixed format.
///
/// Skips zero-byte files (unused O_EXCL reservations).
///
/// `dir` must be an ABSOLUTE path — `openDirAbsolute` rejects
/// relative paths. `resolveDir` normalizes to absolute on the
/// happy path; user configs supplying a relative
/// `chat_persist_dir` get the normalized result.
///
/// Uses `std.Io.Dir` + `std.Io.File.stat` (NOT a hand-rolled
/// libc `struct dirent`/`struct stat`) so the layouts stay
/// correct across glibc / musl / x86_64 / aarch64.
pub fn listDialogs(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) ![]DialogMeta {
    if (dir.len == 0) return allocator.alloc(DialogMeta, 0);

    var d = std.Io.Dir.openDirAbsolute(io, dir, .{ .iterate = true }) catch {
        return allocator.alloc(DialogMeta, 0);
    };
    defer d.close(io);

    var list: std.ArrayList(DialogMeta) = .empty;
    errdefer {
        for (list.items) |m| freeDialogMeta(allocator, m);
        list.deinit(allocator);
    }

    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!matchesDialogStem(entry.name)) continue;

        // Skip zero-byte reservations. `std.Io.File.stat` uses
        // Zig's per-arch Stat plumbing — no manual layout
        // assumptions. The previous direct-fstat path embedded a
        // glibc-x86_64-specific Stat shape that misread st_size
        // on aarch64-musl.
        var file = d.openFile(io, entry.name, .{}) catch continue;
        defer file.close(io);
        const st = file.stat(io) catch continue;
        if (st.size == 0) continue;

        const child_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, entry.name });
        const stem_len = entry.name.len - ".jsonl".len;
        const name_owned = try allocator.dupe(u8, entry.name[0..stem_len]);
        // Read a bounded prefix via libc (the std.Io.File reader
        // we hold open for stat doesn't expose a plain read here).
        // Best-effort — any I/O / parse / shape failure yields an
        // empty preview, matching the picker's render contract.
        const preview = readFirstUserPreview(allocator, child_path) catch try allocator.alloc(u8, 0);
        try list.append(allocator, .{ .path = child_path, .name = name_owned, .preview = preview });
    }

    const result = try list.toOwnedSlice(allocator);
    // Newest-first: lexicographic descending on basename.
    std.mem.sort(DialogMeta, result, {}, sortDialogMetaNewestFirst);
    return result;
}

fn sortDialogMetaNewestFirst(_: void, a: DialogMeta, b: DialogMeta) bool {
    return std.mem.lessThan(u8, b.name, a.name);
}

/// Read up to PREVIEW_PROBE_BYTES from the file at `path` and
/// return the first user-turn content (truncated, control-byte-
/// stripped, owned by `allocator`). Empty slice when no user turn
/// is found in the prefix, the parse fails, or the file is
/// unreadable. The caller takes ownership.
fn readFirstUserPreview(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const PREVIEW_PROBE_BYTES: usize = 4096;
    const PREVIEW_MAX_COLS: usize = 64;

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = open(path_z.ptr, O_RDONLY);
    if (fd < 0) return allocator.alloc(u8, 0);
    defer _ = close(fd);

    var buf: [PREVIEW_PROBE_BYTES]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) {
        const got = read(fd, buf[n..].ptr, buf.len - n);
        if (got <= 0) break;
        n += @intCast(got);
    }
    const data = buf[0..n];

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const Wire = struct {
            kind: []const u8,
            content: []const u8,
        };
        const parsed = std.json.parseFromSlice(Wire, allocator, line, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.kind, "user")) continue;
        const raw = parsed.value.content;
        if (raw.len == 0) return allocator.alloc(u8, 0);
        // Strip ASCII control bytes (incl. \n, \r, \t) so the
        // preview stays on one row, and truncate to PREVIEW_MAX_COLS
        // bytes — close enough to columns for typical English input
        // without dragging in the full UTF-8 width calculator.
        const take = @min(raw.len, PREVIEW_MAX_COLS);
        var out = try allocator.alloc(u8, take);
        errdefer allocator.free(out);
        var j: usize = 0;
        for (raw[0..take]) |c| {
            if (c < 0x20 or c == 0x7F) {
                out[j] = ' ';
            } else {
                out[j] = c;
            }
            j += 1;
        }
        return out;
    }
    return allocator.alloc(u8, 0);
}

/// `YYYYMMDDTHHMMSS-XXXXXX.jsonl` — 15 + 1 + 6 + 6 = 28 bytes.
/// Locks `listDialogs` (and therefore `pruneOldest`) to the
/// format `createSessionPath` emits, so a stray `notes.jsonl`
/// in the same directory doesn't get sorted, recalled, or
/// unlinked by the retention sweep.
fn matchesDialogStem(name: []const u8) bool {
    if (name.len != 28) return false;
    if (!std.mem.endsWith(u8, name, ".jsonl")) return false;
    const stem = name[0 .. name.len - ".jsonl".len];
    if (stem.len != 22) return false;
    // YYYYMMDDTHHMMSS — 8 digits, 'T', 6 digits.
    for (stem[0..8]) |c| if (c < '0' or c > '9') return false;
    if (stem[8] != 'T') return false;
    for (stem[9..15]) |c| if (c < '0' or c > '9') return false;
    if (stem[15] != '-') return false;
    // 6 hex chars.
    for (stem[16..22]) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) return false;
    }
    return true;
}

/// Best-effort retention sweep. Drops the OLDEST entries beyond
/// `keep_count` by `unlink`ing them. Caller invokes from `attach`
/// before reserving the new session path.
pub fn pruneOldest(allocator: std.mem.Allocator, io: std.Io, dir: []const u8, keep_count: usize) void {
    if (dir.len == 0 or keep_count == 0) return;
    const list = listDialogs(allocator, io, dir) catch return;
    defer freeDialogMetaList(allocator, list);
    if (list.len <= keep_count) return;
    // listDialogs is newest-first; oldest live at the tail.
    for (list[keep_count..]) |m| {
        const z = allocator.dupeZ(u8, m.path) catch continue;
        defer allocator.free(z);
        _ = unlink(z.ptr);
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

// ===========================================================================
// Tests — extracted to `chat_persist_tests.zig` for readability.
// ===========================================================================

test {
    _ = @import("chat_persist_tests.zig");
}
