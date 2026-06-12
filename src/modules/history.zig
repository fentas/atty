//! History module — shell-native ghost completion + recording.
//!
//! Reads / writes the user's actual shell history file (~/.bash_history,
//! ~/.zsh_history, ~/.history, …) so atty's suggestions stay coherent
//! with whatever the shell itself shows in Ctrl-R or arrow-up — and so
//! commands typed through atty are visible to the rest of the user's
//! tooling, atuin or no atuin.
//!
//! This module is intentionally minimal:
//!
//!   - Record: O_APPEND a single line on every committed command. The
//!     POSIX guarantee that O_APPEND writes ≤ PIPE_BUF (4096 B) are
//!     atomic means we don't need a lock even across concurrent atty
//!     sessions on the same file.
//!
//!   - Suggest: maintain an in-memory ring of the most recent N entries
//!     (loaded once at attach, appended on each commit). Ghost lookups
//!     are a linear scan back-to-front for the first prefix match.
//!
//! Format detection: $SHELL on attach. zsh writes its extended-history
//! prefix when configured; bash writes a bare line; everything else
//! gets the bare line too. Multi-line commands (bash `\` continuations,
//! zsh's literal newlines) are NOT modelled — we record the line the
//! user pressed Enter on, period.

const std = @import("std");
const m = @import("../module.zig");

const Allocator = std.mem.Allocator;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn lseek(fd: c_int, offset: i64, whence: c_int) i64;

const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0o100;
const O_APPEND: c_int = 0o2000;
const O_TRUNC: c_int = 0o1000;
const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;
const FILE_MODE: c_int = 0o600;

pub const Match = enum { prefix, substring };

pub const Format = enum {
    /// Resolve from $SHELL at attach time.
    auto,
    /// One command per line.
    bash,
    /// `: <unix_ts>:0;<cmd>\n` — what zsh writes with EXTENDED_HISTORY.
    zsh_extended,
    /// Same as bash; the explicit form for ksh / dash / sh / mksh.
    plain,
};

pub const Config = struct {
    /// Absolute path to the history file. Empty = derive from $SHELL,
    /// e.g. zsh → $HISTFILE or ~/.zsh_history, bash → $HISTFILE or
    /// ~/.bash_history. If derivation fails the module silently
    /// disables itself (better than recording to a wrong file).
    path: []const u8 = "",
    /// Write format. `auto` picks zsh_extended for zsh, bash for bash,
    /// plain for everything else.
    format: Format = .auto,
    /// Record committed commands to the file.
    record: bool = true,
    /// Surface suggestions as ghost text. Disable to record only.
    suggest: bool = true,
    /// In-memory ring size — how many recent entries to keep loaded.
    /// Beyond this the oldest are evicted from the ring (file is
    /// untouched).
    capacity: comptime_int = 5_000,
    /// Longest line we'll bother to record or suggest. Anything longer
    /// is dropped (likely pasted garbage, not a real command).
    max_line: comptime_int = 4096,
    /// Hide the suggestion this long after the user stops typing.
    suggestion_ttl_ms: u64 = 5_000,
    /// Match strategy for ghost suggestions.
    match: Match = .prefix,
};

extern "c" fn clock_gettime(clk_id: c_int, tp: *std.posix.timespec) c_int;

const lib = @import("_lib.zig");
const nowMs = lib.nowMs;

const format = @import("history/format.zig");

fn unixTs() i64 {
    var ts: std.posix.timespec = undefined;
    // CLOCK_REALTIME = 0
    if (clock_gettime(0, &ts) != 0) return 0;
    return @as(i64, ts.sec);
}

pub fn configure(comptime cfg: Config) type {
    return struct {
        pub const name = "history";
        pub const config = cfg;

        pub const Runtime = struct {
            allocator: Allocator,
            /// Resolved absolute path. Empty = module is dormant.
            path: []u8,
            /// Resolved write format.
            format: Format,
            /// Ring of recent entries — newest at the *end* so a
            /// reverse scan returns the most-recent prefix match first.
            /// Each entry is heap-allocated and owned by the runtime.
            entries: std.ArrayList([]u8),
            /// Cleared at TTL expiry so a stale ghost doesn't linger.
            last_keystroke_ms: i64 = 0,
            /// `provideGhostText` writes its result here for `ctx.scratch`
            /// to pick up. We also reuse this buffer across calls.
            cached_match: ?[]const u8 = null,
            /// Scratch storage for `provideGhostList`. Slices into
            /// `entries` items, so valid only until the next ring
            /// mutation. Capped at 9 — matches the default Ctrl+1..9
            /// and Esc+1..9 binding range.
            ghost_list_buf: [9][]const u8 = undefined,
            ghost_list_len: usize = 0,
        };

        pub fn attach(allocator: Allocator, io: std.Io) !Runtime {
            _ = io;
            const resolved_path = try resolvePath(allocator);
            const resolved_format = resolveFormat();

            var entries: std.ArrayList([]u8) = .empty;
            errdefer freeEntries(allocator, &entries);

            if (resolved_path.len > 0) {
                loadRecent(allocator, resolved_path, &entries) catch {
                    // Missing or unreadable file is fine — we'll create
                    // it on first record. Permission errors silently
                    // degrade to record-only with an empty ring.
                };
            }

            return .{
                .allocator = allocator,
                .path = resolved_path,
                .format = resolved_format,
                .entries = entries,
            };
        }

        pub fn detach(rt: *Runtime, io: std.Io) void {
            _ = io;
            freeEntries(rt.allocator, &rt.entries);
            if (rt.path.len > 0) rt.allocator.free(rt.path);
        }

        // ---- path / format resolution -----------------------------------

        fn resolvePath(allocator: Allocator) ![]u8 {
            if (cfg.path.len > 0) return allocator.dupe(u8, cfg.path);

            // Honour $HISTFILE first — both bash and zsh respect it.
            if (getenv("HISTFILE")) |raw| {
                const s = std.mem.sliceTo(raw, 0);
                if (s.len > 0) return allocator.dupe(u8, s);
            }

            const home_raw = getenv("HOME") orelse return allocator.dupe(u8, "");
            const home = std.mem.sliceTo(home_raw, 0);

            const shell_name = shellBaseName();
            const file_name: []const u8 = if (std.mem.eql(u8, shell_name, "zsh"))
                ".zsh_history"
            else if (std.mem.eql(u8, shell_name, "bash"))
                ".bash_history"
            else
                ".history";

            return std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, file_name });
        }

        fn resolveFormat() Format {
            if (cfg.format != .auto) return cfg.format;
            const shell = shellBaseName();
            if (std.mem.eql(u8, shell, "zsh")) return .zsh_extended;
            if (std.mem.eql(u8, shell, "bash")) return .bash;
            return .plain;
        }

        fn shellBaseName() []const u8 {
            const raw = getenv("SHELL") orelse return "";
            const s = std.mem.sliceTo(raw, 0);
            // basename — last segment after '/'
            if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| return s[i + 1 ..];
            return s;
        }

        // ---- ring helpers -----------------------------------------------

        fn freeEntries(allocator: Allocator, entries: *std.ArrayList([]u8)) void {
            for (entries.items) |e| allocator.free(e);
            entries.deinit(allocator);
        }

        /// Insert `line` at the end, evicting the oldest entry if at
        /// capacity. `line` is duplicated; caller retains ownership of
        /// the input slice.
        pub fn pushEntry(rt: *Runtime, line: []const u8) !void {
            if (line.len == 0 or line.len > cfg.max_line) return;
            const owned = try rt.allocator.dupe(u8, line);
            errdefer rt.allocator.free(owned);
            if (rt.entries.items.len >= cfg.capacity) {
                const oldest = rt.entries.orderedRemove(0);
                rt.allocator.free(oldest);
            }
            try rt.entries.append(rt.allocator, owned);
        }

        /// Read the tail of `path`, parse out command lines (format-
        /// agnostic), and seed the ring. Best-effort.
        fn loadRecent(allocator: Allocator, path: []const u8, entries: *std.ArrayList([]u8)) !void {
            const path_z = try allocator.dupeZ(u8, path);
            defer allocator.free(path_z);

            const fd = open(path_z.ptr, O_RDONLY);
            if (fd < 0) return;
            defer _ = close(fd);

            // 1 MiB cap; older entries beyond that are ignored. Seek to
            // the TAIL of the file (the file's tail is the *newest*
            // history) — reading from offset 0 would seed the ring with
            // the oldest commands on any history larger than the cap, so
            // ghost suggestions would surface stale entries and never the
            // recent ones the user actually wants.
            const max = 1 << 20;
            const size = lseek(fd, 0, SEEK_END);
            if (size < 0) return;
            var start_off: i64 = 0;
            if (size > max) start_off = size - max;
            // When seeking into the middle, read from one byte BEFORE the
            // window so we can tell whether it begins exactly at a line
            // boundary (keep the first line whole) vs mid-line (drop the
            // partial first line). Mirrors llm/chat_persist's tail read.
            // The SEEK_END probe above left the cursor at EOF, so the
            // rewind is required even for start_off == 0. On seek failure
            // refuse rather than fall back to the head (which would
            // re-seed the ring with the OLDEST entries — the bug fixed
            // here).
            const read_off = if (start_off > 0) start_off - 1 else 0;
            if (lseek(fd, read_off, SEEK_SET) < 0) return;

            const data = try allocator.alloc(u8, max + 1);
            defer allocator.free(data);

            var total: usize = 0;
            while (total < data.len) {
                const rc = std.c.read(fd, data[total..].ptr, data.len - total);
                if (rc < 0) return; // read error — don't seed a partial ring
                if (rc == 0) break;
                total += @intCast(rc);
            }
            var slice = data[0..total];

            if (start_off > 0) {
                // slice[0] is the byte preceding the window: '\n' means
                // the window starts on a fresh line (keep from index 1),
                // otherwise drop the partial first line.
                if (slice.len > 0 and slice[0] == '\n') {
                    slice = slice[1..];
                } else if (std.mem.indexOfScalar(u8, slice, '\n')) |nl| {
                    slice = slice[nl + 1 ..];
                } else {
                    slice = slice[0..0];
                }
            }

            var it = std.mem.splitScalar(u8, slice, '\n');
            while (it.next()) |raw_line| {
                const parsed = parseHistoryLine(raw_line);
                if (parsed.len == 0 or parsed.len > cfg.max_line) continue;
                const owned = try allocator.dupe(u8, parsed);
                errdefer allocator.free(owned);
                if (entries.items.len >= cfg.capacity) {
                    const oldest = entries.orderedRemove(0);
                    allocator.free(oldest);
                }
                try entries.append(allocator, owned);
            }
        }

        /// Strip the zsh extended-history prefix (`: <ts>:<dur>;`) if
        /// present, otherwise return the line as-is. bash lines have
        /// no prefix.
        /// Re-export of the pure line parser from `history/format.zig`.
        /// Lives there because it's cfg-agnostic; surfaced here so
        /// internal callers + existing tests keep their `H.parseHistoryLine`
        /// call sites unchanged.
        pub const parseHistoryLine = format.parseHistoryLine;

        // ---- file write -------------------------------------------------

        fn writeLine(rt: *Runtime, line: []const u8) !void {
            if (rt.path.len == 0) return;
            const path_z = try rt.allocator.dupeZ(u8, rt.path);
            defer rt.allocator.free(path_z);

            const fd = open(path_z.ptr, O_WRONLY | O_APPEND | O_CREAT, FILE_MODE);
            if (fd < 0) return;
            defer _ = close(fd);

            // Build the whole record in one buffer so the O_APPEND
            // write is a single atomic syscall (≤ PIPE_BUF = 4096
            // bytes; max_line caps us at that).
            var buf: [cfg.max_line + 64]u8 = undefined;
            const out = format.formatHistoryLine(&buf, line, rt.format, unixTs()) orelse return;
            _ = std.c.write(fd, out.ptr, out.len);
        }

        /// Re-export of the pure line formatter from `history/format.zig`.
        /// Same rationale as `parseHistoryLine` — cfg-agnostic, lives in
        /// the sibling file, surfaced here for legacy call sites and
        /// tests.
        pub const formatHistoryLine = format.formatHistoryLine;

        // ---- hooks ------------------------------------------------------

        pub fn onInput(rt: *Runtime, _: *m.Context, input: []const u8) m.Error!m.Action {
            _ = input;
            rt.last_keystroke_ms = nowMs();
            rt.cached_match = null;
            return .forward;
        }

        pub fn onLineCommit(rt: *Runtime, ctx: *m.Context, line: []const u8) m.Error!void {
            if (!cfg.record) return;
            if (line.len == 0 or line.len > cfg.max_line) return;
            // Skip commits typed inside a recognised subprocess
            // (ssh / sudo bash / kubectl exec / docker exec / etc.)
            // — those don't belong in the local shell's
            // `~/.bash_history` / `~/.zsh_history`. atuin's record
            // path captures them with an encoded `--cwd` so they
            // remain searchable via `[ DIRECTORY ]`; the shell-
            // native history file stays clean of unrunnable lines
            // that would surface in the shell's own up-arrow recall.
            if (ctx.subprocess) |tr| if (tr.current()) |frame| {
                if (frame.kind != .none) return;
            };
            // Best-effort: failure here must not propagate up. A
            // missing history file is normal on first run; permission
            // errors on a stranger's machine shouldn't crash atty.
            writeLine(rt, line) catch {};
            pushEntry(rt, line) catch {};
        }

        /// Remove every entry whose payload equals `line` from both the
        /// in-memory ring and the on-disk file. Atomic via the
        /// write-temp + rename trick so a crash leaves the original in
        /// place. Best-effort: a file-write failure leaves the
        /// in-memory ring filtered but the on-disk file untouched.
        pub fn deleteHistoryMatch(rt: *Runtime, _: *m.Context, line: []const u8) m.Error!void {
            if (line.len == 0) return;
            // Filter the ring in place.
            var i: usize = 0;
            while (i < rt.entries.items.len) {
                if (std.mem.eql(u8, rt.entries.items[i], line)) {
                    const removed = rt.entries.orderedRemove(i);
                    rt.allocator.free(removed);
                    continue; // don't advance; the next item shifted into i
                }
                i += 1;
            }
            // Filter the real on-disk file.
            filterFileRemoving(rt, line) catch {};
        }

        /// Filter the on-disk history file: read it in full (capped at
        /// `max_file`), drop every line whose parsed payload equals
        /// `line`, keep every other line VERBATIM, then atomically
        /// replace the original via temp + rename.
        ///
        /// Keeping raw lines (rather than re-serialising the in-memory
        /// ring) is load-bearing: the ring holds at most `capacity`
        /// entries seeded from only the file's 1 MiB tail, so dumping it
        /// back would truncate every older entry AND rewrite zsh
        /// extended-history timestamps to "now". Verbatim copy preserves
        /// both. Files larger than `max_file` are left untouched (the
        /// ring is still filtered) — a best-effort cap that never
        /// corrupts, unlike the previous ring-dump.
        ///
        /// The read→filter→rename window is not locked against a
        /// concurrent `writeLine` (O_APPEND) from another atty session,
        /// so a command recorded after the read but before the rename can
        /// be clobbered. Accepted: delete is a deliberate, rare action
        /// and the contract is best-effort; the original is only ever
        /// replaced by a fully-written temp (rename is the sole
        /// mutation), so truncation/corruption is impossible.
        fn filterFileRemoving(rt: *Runtime, line: []const u8) !void {
            if (rt.path.len == 0) return;
            const path_z = try rt.allocator.dupeZ(u8, rt.path);
            defer rt.allocator.free(path_z);

            const rfd = open(path_z.ptr, O_RDONLY);
            if (rfd < 0) return; // nothing on disk to filter
            defer _ = close(rfd);
            const max_file = 64 << 20;
            const size = lseek(rfd, 0, SEEK_END);
            if (size < 0 or size > max_file or lseek(rfd, 0, SEEK_SET) < 0) return;
            const data = try rt.allocator.alloc(u8, @intCast(size));
            defer rt.allocator.free(data);
            var total: usize = 0;
            while (total < data.len) {
                const rc = std.c.read(rfd, data[total..].ptr, data.len - total);
                if (rc < 0) return; // read error before EOF — abort WITHOUT
                // rewriting, or we'd replace the history with a truncated copy
                if (rc == 0) break; // EOF (file shrank concurrently)
                total += @intCast(rc);
            }
            const content = data[0..total];

            var out_buf: std.ArrayList(u8) = .empty;
            defer out_buf.deinit(rt.allocator);
            var removed_any = false;
            var start: usize = 0;
            while (start < content.len) {
                const nl = std.mem.indexOfScalarPos(u8, content, start, '\n');
                const end = nl orelse content.len;
                const raw = content[start..end];
                if (std.mem.eql(u8, parseHistoryLine(raw), line)) {
                    removed_any = true;
                } else {
                    try out_buf.appendSlice(rt.allocator, raw);
                    if (nl != null) try out_buf.append(rt.allocator, '\n');
                }
                start = if (nl) |p| p + 1 else content.len;
            }
            // Nothing on disk matched — don't churn the file.
            if (!removed_any) return;

            const tmp_path = try std.fmt.allocPrint(rt.allocator, "{s}.atty-tmp", .{rt.path});
            defer rt.allocator.free(tmp_path);
            const tmp_z = try rt.allocator.dupeZ(u8, tmp_path);
            defer rt.allocator.free(tmp_z);

            const wfd = open(tmp_z.ptr, O_WRONLY | O_CREAT | O_TRUNC, FILE_MODE);
            if (wfd < 0) return error.WriteFailed;
            defer _ = close(wfd);
            // Clean up the temp on any failure before the rename so a
            // partial write doesn't litter a `.atty-tmp` next to the
            // history file. The original is untouched until the rename.
            errdefer _ = std.c.unlink(tmp_z.ptr);
            var written: usize = 0;
            while (written < out_buf.items.len) {
                const rc = std.c.write(wfd, out_buf.items[written..].ptr, out_buf.items.len - written);
                if (rc <= 0) return error.WriteFailed;
                written += @intCast(rc);
            }

            // rename(tmp, path) — atomic replacement on POSIX.
            if (std.c.rename(tmp_z.ptr, path_z.ptr) != 0) return error.WriteFailed;
        }

        pub fn provideGhostText(rt: *Runtime, ctx: *m.Context) m.Error!?[]const u8 {
            if (!cfg.suggest) return null;
            if (ctx.line.uncertain) return null;
            const query = ctx.line.current();
            if (query.len == 0) return null;
            if (query.len > cfg.max_line) return null;

            const match = findSuggestion(rt, query) orelse return null;
            if (match.len <= query.len) return null;

            const trailing = match[query.len..];
            ctx.scratch.clearRetainingCapacity();
            ctx.scratch.appendSlice(ctx.allocator, trailing) catch return m.Error.OutOfMemory;
            return ctx.scratch.items;
        }

        pub fn findSuggestion(rt: *Runtime, query: []const u8) ?[]const u8 {
            // Walk newest → oldest, return the first entry that
            // startsWith the query (and is strictly longer, so we have
            // a non-empty trailing portion to render). The substring
            // mode is reserved — ghost rendering only paints the tail
            // past the query position, so non-prefix matches would
            // need a different render path. Until that lands we treat
            // .substring as prefix.
            var i: usize = rt.entries.items.len;
            while (i > 0) {
                i -= 1;
                const e = rt.entries.items[i];
                if (std.mem.startsWith(u8, e, query) and e.len > query.len) return e;
            }
            return null;
        }

        /// Up to 9 newest-first prefix-matches for the current line.
        /// Skips the entry that `provideGhostText` would have returned
        /// (so the multi-row list complements rather than duplicates
        /// the inline ghost) and deduplicates by content (history rings
        /// can have repeated entries; users want distinct picks).
        /// Returns null when no candidates exist; the proxy renders
        /// nothing in that case.
        pub fn provideGhostList(rt: *Runtime, ctx: *m.Context) m.Error!?[]const []const u8 {
            if (!cfg.suggest) return null;
            if (ctx.line.uncertain) return null;
            const query = ctx.line.current();
            if (query.len == 0) return null;
            if (query.len > cfg.max_line) return null;

            const inline_match = findSuggestion(rt, query); // already shown inline

            var builder = lib.ListBuilder(rt.ghost_list_buf.len){};
            var i: usize = rt.entries.items.len;
            while (i > 0 and !builder.full()) : (i -= 1) {
                const e = rt.entries.items[i - 1];
                if (!std.mem.startsWith(u8, e, query)) continue;
                if (e.len <= query.len) continue;
                _ = builder.tryAdd(e, inline_match);
            }
            if (builder.len == 0) return null;
            // Spill into rt's persistent storage so the slice survives
            // past the local builder. The builder's items() slice
            // borrows from `buf` which lives on the stack frame.
            @memcpy(rt.ghost_list_buf[0..builder.len], builder.items());
            rt.ghost_list_len = builder.len;
            return rt.ghost_list_buf[0..rt.ghost_list_len];
        }

        pub fn onTick(rt: *Runtime, _: *m.Context, elapsed_ms: u64) m.Error!void {
            _ = elapsed_ms;
            if (rt.last_keystroke_ms == 0) return;
            const idle = nowMs() - rt.last_keystroke_ms;
            if (idle <= 0) return;
            if (@as(u64, @intCast(idle)) >= cfg.suggestion_ttl_ms) {
                rt.cached_match = null;
            }
        }
    };
}

// ===========================================================================
// Tests — extracted to `history_tests.zig` for readability.
// ===========================================================================

test {
    _ = @import("history_tests.zig");
}
