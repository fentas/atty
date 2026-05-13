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

const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0o100;
const O_APPEND: c_int = 0o2000;
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
        fn pushEntry(rt: *Runtime, line: []const u8) !void {
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

            // 1 MiB cap; older entries beyond that are ignored.
            const max = 1 << 20;
            const data = try allocator.alloc(u8, max);
            defer allocator.free(data);

            var total: usize = 0;
            while (total < max) {
                const rc = std.c.read(fd, data[total..].ptr, max - total);
                if (rc <= 0) break;
                total += @intCast(rc);
            }
            const slice = data[0..total];

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
        fn parseHistoryLine(line: []const u8) []const u8 {
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (trimmed.len < 4 or trimmed[0] != ':' or trimmed[1] != ' ') return trimmed;
            const semi = std.mem.indexOfScalar(u8, trimmed, ';') orelse return trimmed;
            return trimmed[semi + 1 ..];
        }

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
            const out = formatHistoryLine(&buf, line, rt.format, unixTs()) orelse return;
            _ = std.c.write(fd, out.ptr, out.len);
        }

        /// Pure formatting helper — separable from the file I/O so it
        /// can be unit-tested without touching disk.
        fn formatHistoryLine(buf: []u8, line: []const u8, format: Format, ts: i64) ?[]const u8 {
            var w = std.Io.Writer.fixed(buf);
            switch (format) {
                .zsh_extended => w.print(": {d}:0;", .{ts}) catch return null,
                else => {},
            }
            w.writeAll(line) catch return null;
            w.writeByte('\n') catch return null;
            return w.buffered();
        }

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

        /// Remove every ring entry whose payload equals `line`, then
        /// rewrite the file with what's left. Atomic via the
        /// write-temp + rename trick so a crash leaves the original
        /// in place. Best-effort: a file-write failure leaves the
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
            // Rewrite the file atomically.
            rewriteFile(rt) catch {};
        }

        /// Write the current ring to disk via a temp + rename so a
        /// crash or write failure can't corrupt the user's history.
        fn rewriteFile(rt: *Runtime) !void {
            if (rt.path.len == 0) return;

            const tmp_path = try std.fmt.allocPrint(rt.allocator, "{s}.atty-tmp", .{rt.path});
            defer rt.allocator.free(tmp_path);
            const tmp_z = try rt.allocator.dupeZ(u8, tmp_path);
            defer rt.allocator.free(tmp_z);
            const path_z = try rt.allocator.dupeZ(u8, rt.path);
            defer rt.allocator.free(path_z);

            const fd = open(tmp_z.ptr, O_WRONLY | O_CREAT | 0o1000, FILE_MODE); // 0o1000 = O_TRUNC
            if (fd < 0) return error.WriteFailed;
            defer _ = close(fd);

            var buf: [cfg.max_line + 64]u8 = undefined;
            for (rt.entries.items) |entry| {
                const out = formatHistoryLine(&buf, entry, rt.format, unixTs()) orelse continue;
                _ = std.c.write(fd, out.ptr, out.len);
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

        fn findSuggestion(rt: *Runtime, query: []const u8) ?[]const u8 {
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
// Tests
// ===========================================================================

const testing = std.testing;

test "configure exposes Runtime + hooks" {
    const H = configure(.{});
    try testing.expect(@hasDecl(H, "Runtime"));
    try testing.expect(@hasDecl(H, "onLineCommit"));
    try testing.expect(@hasDecl(H, "provideGhostText"));
    try testing.expectEqualStrings("history", H.name);
}

test "parseHistoryLine strips zsh extended prefix" {
    const H = configure(.{});
    try testing.expectEqualStrings("ls -la", H.parseHistoryLine(": 1700000000:0;ls -la"));
    try testing.expectEqualStrings("echo hi", H.parseHistoryLine("echo hi"));
    try testing.expectEqualStrings("", H.parseHistoryLine(""));
    // Lines without the colon prefix are returned as-is.
    try testing.expectEqualStrings(":not-extended", H.parseHistoryLine(":not-extended"));
}

test "ring evicts oldest at capacity" {
    const H = configure(.{ .capacity = 3 });
    var rt: H.Runtime = .{
        .allocator = testing.allocator,
        .path = try testing.allocator.dupe(u8, ""),
        .format = .plain,
        .entries = .empty,
    };
    defer H.detach(&rt, std.Io.failing);

    try H.pushEntry(&rt, "one");
    try H.pushEntry(&rt, "two");
    try H.pushEntry(&rt, "three");
    try H.pushEntry(&rt, "four"); // evicts "one"

    try testing.expectEqual(@as(usize, 3), rt.entries.items.len);
    try testing.expectEqualStrings("two", rt.entries.items[0]);
    try testing.expectEqualStrings("four", rt.entries.items[2]);
}

test "findSuggestion returns the most recent prefix match" {
    const H = configure(.{});
    var rt: H.Runtime = .{
        .allocator = testing.allocator,
        .path = try testing.allocator.dupe(u8, ""),
        .format = .plain,
        .entries = .empty,
    };
    defer H.detach(&rt, std.Io.failing);

    try H.pushEntry(&rt, "git status");
    try H.pushEntry(&rt, "git push origin");
    try H.pushEntry(&rt, "ls -la");

    const got = H.findSuggestion(&rt, "git ") orelse return error.TestFailed;
    try testing.expectEqualStrings("git push origin", got);
}

test "formatHistoryLine emits zsh extended prefix" {
    const H = configure(.{});
    var buf: [128]u8 = undefined;
    const out = H.formatHistoryLine(&buf, "ls -la", .zsh_extended, 1_700_000_000).?;
    try testing.expectEqualStrings(": 1700000000:0;ls -la\n", out);
}

test "formatHistoryLine bash + plain emit bare lines" {
    const H = configure(.{});
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("git status\n", H.formatHistoryLine(&buf, "git status", .bash, 0).?);
    try testing.expectEqualStrings("ls\n", H.formatHistoryLine(&buf, "ls", .plain, 0).?);
}

test "formatHistoryLine round-trips through parseHistoryLine" {
    const H = configure(.{});
    var buf: [128]u8 = undefined;
    const formatted = H.formatHistoryLine(&buf, "echo hi", .zsh_extended, 42).?;
    const without_nl = std.mem.trimEnd(u8, formatted, "\n");
    try testing.expectEqualStrings("echo hi", H.parseHistoryLine(without_nl));
}

test "onLineCommit pushes into the ring" {
    const H = configure(.{});
    var rt: H.Runtime = .{
        .allocator = testing.allocator,
        .path = try testing.allocator.dupe(u8, ""), // empty path = no file I/O
        .format = .plain,
        .entries = .empty,
    };
    defer H.detach(&rt, std.Io.failing);

    var line: @import("../line_state.zig").LineState = .{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = std.Io.failing,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    try H.onLineCommit(&rt, &ctx, "ls -la");
    try H.onLineCommit(&rt, &ctx, "git status");
    try testing.expectEqual(@as(usize, 2), rt.entries.items.len);
    try testing.expectEqualStrings("git status", rt.entries.items[1]);
}

test "findSuggestion ignores entries equal to query (no useful trailing)" {
    const H = configure(.{});
    var rt: H.Runtime = .{
        .allocator = testing.allocator,
        .path = try testing.allocator.dupe(u8, ""),
        .format = .plain,
        .entries = .empty,
    };
    defer H.detach(&rt, std.Io.failing);

    try H.pushEntry(&rt, "ls");
    try testing.expectEqual(@as(?[]const u8, null), H.findSuggestion(&rt, "ls"));
}

test "deleteHistoryMatch removes every matching ring entry" {
    const H = configure(.{});
    var rt: H.Runtime = .{
        .allocator = testing.allocator,
        // Empty path → file write path is a no-op, ring is the
        // only thing we test here.
        .path = try testing.allocator.dupe(u8, ""),
        .format = .plain,
        .entries = .empty,
    };
    defer H.detach(&rt, std.Io.failing);

    try H.pushEntry(&rt, "ls");
    try H.pushEntry(&rt, "rm -rf /tmp/secret");
    try H.pushEntry(&rt, "echo hi");
    try H.pushEntry(&rt, "rm -rf /tmp/secret"); // duplicate
    try H.pushEntry(&rt, "ls -la");

    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var line: @import("../line_state.zig").LineState = .{};
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = std.Io.failing,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    try H.deleteHistoryMatch(&rt, &ctx, "rm -rf /tmp/secret");

    // Both duplicates gone, other entries preserved in order.
    try testing.expectEqual(@as(usize, 3), rt.entries.items.len);
    try testing.expectEqualStrings("ls", rt.entries.items[0]);
    try testing.expectEqualStrings("echo hi", rt.entries.items[1]);
    try testing.expectEqualStrings("ls -la", rt.entries.items[2]);
}

test "deleteHistoryMatch is a no-op for an empty query" {
    const H = configure(.{});
    var rt: H.Runtime = .{
        .allocator = testing.allocator,
        .path = try testing.allocator.dupe(u8, ""),
        .format = .plain,
        .entries = .empty,
    };
    defer H.detach(&rt, std.Io.failing);

    try H.pushEntry(&rt, "ls");

    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var line: @import("../line_state.zig").LineState = .{};
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = std.Io.failing,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    try H.deleteHistoryMatch(&rt, &ctx, "");
    try testing.expectEqual(@as(usize, 1), rt.entries.items.len);
}

test "loadRecent populates the ring from an existing file" {
    // Write three lines to a temp path, then ask history.attach to
    // load them. Run inside a fresh /tmp file unique to this test so
    // we don't collide with the user's real history or with the e2e
    // scenarios that use their own fixed paths.
    const path = "/tmp/atty-unit-history-load.txt";

    // Write the file.
    const path_z = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(path_z);
    _ = std.c.unlink(path_z.ptr); // ensure clean slate
    const fd = std.c.open(
        path_z.ptr,
        @bitCast(std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }),
        @as(std.c.mode_t, 0o600),
    );
    try testing.expect(fd >= 0);
    const payload = "echo one\necho two\necho three\n";
    _ = std.c.write(fd, payload.ptr, payload.len);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path_z.ptr);

    const H = configure(.{ .path = path, .format = .plain });
    var rt = try H.attach(testing.allocator, std.Io.failing);
    defer H.detach(&rt, std.Io.failing);

    try testing.expectEqual(@as(usize, 3), rt.entries.items.len);
    try testing.expectEqualStrings("echo one", rt.entries.items[0]);
    try testing.expectEqualStrings("echo three", rt.entries.items[2]);
}

test "provideGhostList returns newest-first prefix matches, skipping the inline ghost and dupes" {
    const H = configure(.{});
    var rt: H.Runtime = .{
        .allocator = testing.allocator,
        .path = try testing.allocator.dupe(u8, ""),
        .format = .plain,
        .entries = .empty,
    };
    defer H.detach(&rt, std.Io.failing);

    // Push entries oldest → newest. With duplicates.
    try H.pushEntry(&rt, "git log");
    try H.pushEntry(&rt, "git commit -m foo");
    try H.pushEntry(&rt, "git push origin master");
    try H.pushEntry(&rt, "git commit -m foo"); // dup
    try H.pushEntry(&rt, "git status");

    var line: @import("../line_state.zig").LineState = .{};
    _ = line.applyInput("git ");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = std.Io.failing,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    const got = (try H.provideGhostList(&rt, &ctx)).?;

    // Inline ghost would have been "git status" (newest match).
    // The list starts after, newest-first, deduped:
    //   - "git commit -m foo" appears TWICE in the ring; the newer
    //     instance is the 4th push (after "git push origin master"),
    //     so the newest-first walk hits it before "git push" and
    //     dedupe drops the older copy at position 1.
    //   - "git push origin master" is older than the dup, so it
    //     ranks below "git commit -m foo".
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("git commit -m foo", got[0]);
    try testing.expectEqualStrings("git push origin master", got[1]);
    try testing.expectEqualStrings("git log", got[2]);
}

test "provideGhostList returns null on empty query / uncertain line" {
    const H = configure(.{});
    var rt: H.Runtime = .{
        .allocator = testing.allocator,
        .path = try testing.allocator.dupe(u8, ""),
        .format = .plain,
        .entries = .empty,
    };
    defer H.detach(&rt, std.Io.failing);
    try H.pushEntry(&rt, "anything");

    var line: @import("../line_state.zig").LineState = .{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = std.Io.failing,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    // Empty line: null.
    try testing.expectEqual(@as(?[]const []const u8, null), try H.provideGhostList(&rt, &ctx));

    // Mark uncertain (simulate arrow key): still null even with a typed prefix.
    _ = line.applyInput("a");
    _ = line.applyInput("\x1b[A"); // up arrow → uncertain
    try testing.expect(line.uncertain);
    try testing.expectEqual(@as(?[]const []const u8, null), try H.provideGhostList(&rt, &ctx));
}

test "provideGhostList caps at 9 entries (matches Ctrl+1..Ctrl+9 / Esc+1..9 default bindings)" {
    const H = configure(.{ .capacity = 32 });
    var rt: H.Runtime = .{
        .allocator = testing.allocator,
        .path = try testing.allocator.dupe(u8, ""),
        .format = .plain,
        .entries = .empty,
    };
    defer H.detach(&rt, std.Io.failing);

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        var buf: [32]u8 = undefined;
        const entry = try std.fmt.bufPrint(&buf, "x cmd-{d}", .{i});
        try H.pushEntry(&rt, entry);
    }

    var line: @import("../line_state.zig").LineState = .{};
    _ = line.applyInput("x ");
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = std.Io.failing,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    const got = (try H.provideGhostList(&rt, &ctx)).?;
    try testing.expectEqual(@as(usize, 9), got.len);
}

test "deleteHistoryMatch rewrites the on-disk file atomically" {
    // The in-memory ring filter is the visible behaviour, but the
    // atomic rewrite (write-temp + rename) is the durability story.
    // If the file isn't rewritten the deleted entry comes back on
    // the next atty session — that's the user-facing regression.
    const path = "/tmp/atty-unit-history-delete-roundtrip.txt";
    const path_z = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(path_z);
    _ = std.c.unlink(path_z.ptr);
    const fd = std.c.open(
        path_z.ptr,
        @bitCast(std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }),
        @as(std.c.mode_t, 0o600),
    );
    try testing.expect(fd >= 0);
    const payload = "keep one\nDELETE-ME\nkeep two\nDELETE-ME\n";
    _ = std.c.write(fd, payload.ptr, payload.len);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path_z.ptr);

    const H = configure(.{ .path = path, .format = .plain });
    var rt = try H.attach(testing.allocator, std.Io.failing);
    defer H.detach(&rt, std.Io.failing);

    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    var line: @import("../line_state.zig").LineState = .{};
    var ctx = m.Context{
        .allocator = testing.allocator,
        .io = std.Io.failing,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    try H.deleteHistoryMatch(&rt, &ctx, "DELETE-ME");

    // Ring: 4 → 2.
    try testing.expectEqual(@as(usize, 2), rt.entries.items.len);

    // File: re-read and confirm the on-disk content matches.
    const rd_fd = std.c.open(path_z.ptr, @bitCast(std.c.O{ .ACCMODE = .RDONLY }), @as(std.c.mode_t, 0));
    try testing.expect(rd_fd >= 0);
    defer _ = std.c.close(rd_fd);
    var buf: [256]u8 = undefined;
    const n = std.c.read(rd_fd, &buf, buf.len);
    try testing.expect(n > 0);
    const disk = buf[0..@as(usize, @intCast(n))];
    try testing.expect(std.mem.indexOf(u8, disk, "DELETE-ME") == null);
    try testing.expect(std.mem.indexOf(u8, disk, "keep one") != null);
    try testing.expect(std.mem.indexOf(u8, disk, "keep two") != null);
}

test "loadRecent strips zsh extended-history prefixes on load" {
    const path = "/tmp/atty-unit-history-zsh.txt";
    const path_z = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(path_z);
    _ = std.c.unlink(path_z.ptr);
    const fd = std.c.open(
        path_z.ptr,
        @bitCast(std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }),
        @as(std.c.mode_t, 0o600),
    );
    try testing.expect(fd >= 0);
    const payload = ": 1700000000:0;echo zsh-style\n: 1700000001:0;ls\n";
    _ = std.c.write(fd, payload.ptr, payload.len);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path_z.ptr);

    const H = configure(.{ .path = path, .format = .zsh_extended });
    var rt = try H.attach(testing.allocator, std.Io.failing);
    defer H.detach(&rt, std.Io.failing);

    try testing.expectEqual(@as(usize, 2), rt.entries.items.len);
    try testing.expectEqualStrings("echo zsh-style", rt.entries.items[0]);
    try testing.expectEqualStrings("ls", rt.entries.items[1]);
}
