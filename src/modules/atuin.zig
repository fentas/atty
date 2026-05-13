//! Atuin module — fish-style history autosuggestion as ghost text,
//! plus manual command recording (since the shell plugin is opt-in and
//! requires ble.sh on bash). atty doing the recording itself means the
//! shell stays vanilla.
//!
//! Architecture (latest-wins mailbox for query, single-pending slot
//! for record):
//!
//!   main thread          shared (mutex)              worker thread
//!   ───────────          ──────────────              ─────────────
//!   onInput     ─────▶   req_buf  ──────────────▶   read latest
//!                        req_gen ↑                   run lookup
//!                                                    write result
//!                                                    res_buf  ◀────
//!                        res_gen ↑
//!   provideGhost ◀───    read res_buf
//!   onLineCommit ───▶    rec_buf  ──────────────▶   run record
//!                        rec_pending ↑              maybe run sync
//!
//! "Sync" here means firing `atuin sync` from the worker after either
//! `sync_after_records` commits or `sync_interval_ms` of wall time,
//! whichever is sooner. The CLI is the source of truth — we never
//! touch atuin's sqlite directly. One final sync runs on detach so an
//! interactive session always flushes before exit.

const std = @import("std");
const m = @import("../module.zig");
const lib = @import("_lib.zig");
const subprocess_mod = @import("../subprocess.zig");
const nowMs = lib.nowMs;

pub const SearchMode = enum { prefix, full_text, fuzzy };
pub const FilterMode = enum { global, host, session, directory };

/// Scope of the `deleteHistoryMatch` action. Atuin's CLI v18 has no
/// exact-match search mode of its own — `prefix` / `full-text` /
/// `fuzzy` all over-match — but **fuzzy mode supports fzf-style
/// anchors**: `^line$` matches commands whose text equals `line`
/// and nothing else. atty defaults to that so Ctrl+Shift+D only
/// removes the line the user is staring at.
pub const DeleteScope = enum {
    /// `atuin search --search-mode fuzzy --delete '^<line>$'`.
    /// True exact-match. Removes only commands equal to the line.
    exact,
    /// `--search-mode prefix --delete <line>`. Removes the line +
    /// any longer command starting with it ("echo asd" → also
    /// removes "echo asdf").
    prefix,
    /// `--search-mode full-text --delete <line>`. Removes any
    /// command containing the line as a substring (anywhere).
    full_text,
    /// `--search-mode fuzzy --delete <line>` (no anchors).
    /// Typo-tolerant; broadest collateral.
    fuzzy,
};
pub const Backend = enum {
    /// Shells out to `atuin search`. Robust, works today.
    subprocess,
    /// Talks to the Atuin daemon socket. Stub — wired in for the day
    /// the IPC protocol stabilises.
    socket,
};

pub const Config = struct {
    backend: Backend = .subprocess,
    atuin_binary: []const u8 = "atuin",
    search_mode: SearchMode = .prefix,
    filter_mode: FilterMode = .global,
    socket_path: []const u8 = "",
    /// Drop the cached suggestion after this many ms of keyboard idle.
    /// `0` disables the timer — the suggestion persists until the user
    /// types something that no longer prefix-matches it (which is how
    /// fish + zsh-autosuggestions behave). Default 0; set to a non-zero
    /// value if you specifically want stale offers to fade.
    suggestion_ttl_ms: u64 = 0,
    max_query: comptime_int = 256,
    /// Bytes of one `atuin search` invocation's stdout we keep.
    /// Sized to hold ~9 newline-separated entries each up to
    /// max_query bytes; bump if list_count_max is raised.
    max_result: comptime_int = 4096,
    /// Worker fetches up to this many matches per query (newest-
    /// first). The inline ghost uses entry 0; the multi-row pick
    /// list (`provideGhostList`) consumes the rest via `_lib.ListBuilder`.
    /// 1 keeps the legacy behavior (single-entry response).
    list_count_max: comptime_int = 9,

    /// Record committed commands via `atuin history start <cmd>`.
    /// Set false to disable recording (suggestions still work).
    record: bool = true,
    /// Fire `atuin sync` after this many recorded commits (per session).
    /// 0 disables the count-based trigger.
    sync_after_records: u32 = 10,
    /// Fire `atuin sync` after this many ms since the previous sync.
    /// 0 disables the time-based trigger.
    sync_interval_ms: u64 = 60_000,
    /// Run one final `atuin sync` on detach if we recorded anything.
    sync_on_detach: bool = true,

    /// Scope of the `deleteHistoryMatch` (Ctrl+Shift+D) action against
    /// atuin's database. Default `.exact` uses atuin's fuzzy mode
    /// with fzf-style `^...$` anchors so only commands *equal* to
    /// the line are removed. See `DeleteScope` for the broader modes
    /// if you want Ctrl+Shift+D to sweep wider.
    delete_scope: DeleteScope = .exact,
};

pub fn configure(comptime cfg: Config) type {
    return struct {
        pub const name = "atuin";
        pub const config = cfg;

        const Shared = struct {
            mutex: std.Io.Mutex = .init,
            cv: std.Io.Condition = .init,

            req_buf: [cfg.max_query]u8 = undefined,
            req_len: usize = 0,
            req_gen: u64 = 0,

            res_buf: [cfg.max_result]u8 = undefined,
            res_len: usize = 0,
            res_gen: u64 = 0,

            // Latest-wins record slot. Two Enter-presses arriving before
            // the worker drains: only the newer is recorded. Acceptable
            // — typing two commands within ~50 ms is rare and we'd
            // rather drop than queue unbounded.
            rec_buf: [cfg.max_query]u8 = undefined,
            rec_len: usize = 0,
            rec_pending: bool = false,
            // Resolved subprocess `--cwd` for the pending record, or
            // empty when none. Captured from `ctx.subprocessCwd(…)` at
            // onLineCommit time so the worker has a stable snapshot
            // even if the user enters a new ssh/sudo/etc. before the
            // worker drains.
            rec_cwd_buf: [subprocess_mod.max_cwd_bytes]u8 = undefined,
            rec_cwd_len: usize = 0,

            shutdown: bool = false,
        };

        pub const Runtime = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            shared: *Shared,
            thread: std.Thread,
            last_keystroke_ms: i64 = 0,
            /// Copy of the worker's response, taken under a brief lock
            /// before `provideGhostList` parses it. Decouples our
            /// returned slice-of-slices from the worker's next write
            /// to `Shared.res_buf`.
            list_copy: [cfg.max_result]u8 = undefined,
            /// Slice-of-slices into `list_copy`, populated by
            /// `provideGhostList` via `_lib.ListBuilder`.
            list_slices: [cfg.list_count_max][]const u8 = undefined,
            list_slices_len: usize = 0,
        };

        pub fn attach(allocator: std.mem.Allocator, io: std.Io) !Runtime {
            const shared = try allocator.create(Shared);
            shared.* = .{};
            errdefer allocator.destroy(shared);

            const thread = try std.Thread.spawn(.{}, worker, .{ shared, io, allocator });
            return .{
                .allocator = allocator,
                .io = io,
                .shared = shared,
                .thread = thread,
            };
        }

        pub fn detach(rt: *Runtime, io: std.Io) void {
            {
                rt.shared.mutex.lockUncancelable(io);
                defer rt.shared.mutex.unlock(io);
                rt.shared.shutdown = true;
                rt.shared.cv.signal(io);
            }
            rt.thread.join();
            rt.allocator.destroy(rt.shared);
        }

        // ---- worker -------------------------------------------------------

        fn worker(shared: *Shared, io: std.Io, gpa: std.mem.Allocator) void {
            var query_local: [cfg.max_query]u8 = undefined;
            var query_len: usize = 0;
            var serving_gen: u64 = 0;

            var record_local: [cfg.max_query]u8 = undefined;
            var record_len: usize = 0;
            var record_cwd_local: [subprocess_mod.max_cwd_bytes]u8 = undefined;
            var record_cwd_len: usize = 0;
            var records_since_sync: u32 = 0;
            var last_sync_ms: i64 = 0;
            var total_records: u32 = 0;

            while (true) {
                shared.mutex.lockUncancelable(io);
                while (!shared.shutdown and
                    shared.req_gen == serving_gen and
                    !shared.rec_pending)
                {
                    shared.cv.waitUncancelable(io, &shared.mutex);
                }
                if (shared.shutdown) {
                    shared.mutex.unlock(io);
                    // Final sync on the way out so an interactive session
                    // leaves no commits stranded locally.
                    if (cfg.record and cfg.sync_on_detach and total_records > 0)
                        runSync(gpa, io);
                    return;
                }

                const has_query = shared.req_gen != serving_gen;
                if (has_query) {
                    serving_gen = shared.req_gen;
                    query_len = shared.req_len;
                    @memcpy(query_local[0..query_len], shared.req_buf[0..query_len]);
                }

                const has_record = shared.rec_pending;
                if (has_record) {
                    record_len = shared.rec_len;
                    @memcpy(record_local[0..record_len], shared.rec_buf[0..record_len]);
                    record_cwd_len = shared.rec_cwd_len;
                    if (record_cwd_len > 0) {
                        @memcpy(record_cwd_local[0..record_cwd_len], shared.rec_cwd_buf[0..record_cwd_len]);
                    }
                    shared.rec_pending = false;
                }
                shared.mutex.unlock(io);

                if (has_query) {
                    var result_buf: [cfg.max_result]u8 = undefined;
                    const maybe_n = lookup(gpa, io, query_local[0..query_len], &result_buf) catch null;
                    shared.mutex.lockUncancelable(io);
                    if (maybe_n) |n| {
                        @memcpy(shared.res_buf[0..n], result_buf[0..n]);
                        shared.res_len = n;
                    } else {
                        shared.res_len = 0;
                    }
                    shared.res_gen = serving_gen;
                    shared.mutex.unlock(io);
                }

                if (has_record and cfg.record) {
                    runRecord(gpa, io, record_local[0..record_len], record_cwd_local[0..record_cwd_len]);
                    total_records += 1;
                    records_since_sync += 1;
                    const now = nowMs();
                    const count_due = cfg.sync_after_records > 0 and records_since_sync >= cfg.sync_after_records;
                    const time_due = cfg.sync_interval_ms > 0 and
                        last_sync_ms > 0 and
                        @as(u64, @intCast(now - last_sync_ms)) >= cfg.sync_interval_ms;
                    if (count_due or time_due or last_sync_ms == 0) {
                        runSync(gpa, io);
                        records_since_sync = 0;
                        last_sync_ms = now;
                    }
                }
            }
        }

        // ---- backends -----------------------------------------------------

        fn lookup(gpa: std.mem.Allocator, io: std.Io, query: []const u8, out: []u8) !?usize {
            if (query.len == 0) return null;
            return switch (cfg.backend) {
                .subprocess => subprocessLookup(gpa, io, query, out),
                .socket => socketLookup(query, out),
            };
        }

        fn subprocessLookup(gpa: std.mem.Allocator, io: std.Io, query: []const u8, out: []u8) !?usize {
            const search_arg = switch (cfg.search_mode) {
                .prefix => "prefix",
                .full_text => "full-text",
                .fuzzy => "fuzzy",
            };
            const filter_arg = switch (cfg.filter_mode) {
                .global => "global",
                .host => "host",
                .session => "session",
                .directory => "directory",
            };
            const limit_arg = std.fmt.comptimePrint("{d}", .{cfg.list_count_max});

            // No --reverse: atuin's default order is newest-first, which
            // is what a "fish-style autosuggest" wants. With --reverse
            // we'd pin the oldest matches at the front.
            //
            // We fetch up to `list_count_max` rows on one round-trip so
            // a single keystroke produces enough data for both the
            // inline ghost (first row) and the multi-row pick list
            // (remaining rows). The proxy reads `cfg.ghost.list_count`
            // from these — bounded above by `list_count_max`.
            const argv = [_][]const u8{
                cfg.atuin_binary,
                "search",
                "--search-mode",
                search_arg,
                "--filter-mode",
                filter_arg,
                "--limit",
                limit_arg,
                "--cmd-only",
                query,
            };

            const result = std.process.run(gpa, io, .{
                .argv = &argv,
                .stdout_limit = .limited(cfg.max_result),
            }) catch return null;
            defer gpa.free(result.stdout);
            defer gpa.free(result.stderr);

            if (result.stdout.len == 0) return null;

            // Trim trailing whitespace (atuin terminates with a final
            // newline). The body — including intermediate newlines —
            // is stored verbatim in `out` so consumers can either:
            //   1. Read up to the first newline (inline ghost)
            //   2. Split on '\n' (multi-entry list)
            var end: usize = result.stdout.len;
            while (end > 0 and (result.stdout[end - 1] == '\n' or result.stdout[end - 1] == '\r')) end -= 1;
            if (end == 0) return null;
            if (end > out.len) end = out.len;
            @memcpy(out[0..end], result.stdout[0..end]);
            return end;
        }

        fn socketLookup(query: []const u8, out: []u8) !?usize {
            _ = query;
            _ = out;
            // TODO: implement once Atuin's IPC protocol stabilises.
            return null;
        }

        /// Fire-and-forget — we don't capture the entry ID. The entry
        /// stays "open" in atuin's DB (no end timestamp, no exit code),
        /// which atuin tolerates gracefully and surfaces in searches.
        /// We accept the imperfect record over the cost of two CLI
        /// invocations + ID tracking. atuin's own shell plugin sets
        /// exit code via PROMPT_COMMAND; we don't see that signal.
        ///
        /// When `cwd` is non-empty, it's passed to atuin as `--cwd`
        /// — the proxy uses this to encode subprocess context (ssh
        /// target, kubectl pod, sudo elevation, …) into the recorded
        /// entry so atuin's `[ DIRECTORY ]` filter on Ctrl+R scopes
        /// commands per remote/elevation target without needing
        /// atuin patches.
        fn runRecord(gpa: std.mem.Allocator, io: std.Io, line: []const u8, cwd: []const u8) void {
            if (line.len == 0) return;
            var argv_buf: [6][]const u8 = undefined;
            var argv_len: usize = 0;
            argv_buf[argv_len] = cfg.atuin_binary;
            argv_len += 1;
            argv_buf[argv_len] = "history";
            argv_len += 1;
            argv_buf[argv_len] = "start";
            argv_len += 1;
            if (cwd.len > 0) {
                argv_buf[argv_len] = "--cwd";
                argv_len += 1;
                argv_buf[argv_len] = cwd;
                argv_len += 1;
            }
            argv_buf[argv_len] = line;
            argv_len += 1;
            const result = std.process.run(gpa, io, .{
                .argv = argv_buf[0..argv_len],
                .stdout_limit = .limited(256),
            }) catch return;
            gpa.free(result.stdout);
            gpa.free(result.stderr);
        }

        /// Spawn `atuin sync` on a detached thread so it doesn't block
        /// the next query. Sync can take seconds (network round-trip);
        /// if we ran it inline the worker would miss every keystroke
        /// during that window, the suggestion cache would go stale,
        /// and the ghost would appear "stuck". The thread is detached
        /// — we never join — so the only cost is one short-lived OS
        /// thread per sync.
        fn runSync(gpa: std.mem.Allocator, io: std.Io) void {
            const t = std.Thread.spawn(.{}, syncOnThread, .{ gpa, io }) catch return;
            t.detach();
        }

        fn syncOnThread(gpa: std.mem.Allocator, io: std.Io) void {
            const argv = [_][]const u8{
                cfg.atuin_binary,
                "sync",
            };
            const result = std.process.run(gpa, io, .{
                .argv = &argv,
                .stdout_limit = .limited(4096),
            }) catch return;
            gpa.free(result.stdout);
            gpa.free(result.stderr);
        }

        // ---- hooks --------------------------------------------------------

        pub fn onInput(rt: *Runtime, ctx: *m.Context, input: []const u8) m.Error!m.Action {
            _ = input;
            rt.last_keystroke_ms = nowMs();

            const line = ctx.line.current();
            if (ctx.line.uncertain or line.len == 0 or line.len > cfg.max_query) {
                return .forward;
            }

            rt.shared.mutex.lockUncancelable(ctx.io);
            defer rt.shared.mutex.unlock(ctx.io);
            @memcpy(rt.shared.req_buf[0..line.len], line);
            rt.shared.req_len = line.len;
            rt.shared.req_gen +%= 1;
            rt.shared.cv.signal(ctx.io);
            return .forward;
        }

        pub fn provideGhostText(rt: *Runtime, ctx: *m.Context) m.Error!?[]const u8 {
            if (ctx.line.uncertain) return null;
            const line = ctx.line.current();
            if (line.len == 0) return null;

            rt.shared.mutex.lockUncancelable(ctx.io);
            defer rt.shared.mutex.unlock(ctx.io);

            if (rt.shared.res_len == 0) return null;
            const all = rt.shared.res_buf[0..rt.shared.res_len];
            // res_buf may hold multiple newline-separated entries (the
            // worker fetches up to `list_count_max` per query). The
            // inline ghost is the FIRST line.
            const nl = std.mem.indexOfScalar(u8, all, '\n') orelse all.len;
            const suggestion = all[0..nl];
            if (suggestion.len == 0) return null;
            if (!std.mem.startsWith(u8, suggestion, line)) return null;

            const trailing = suggestion[line.len..];
            if (trailing.len == 0) return null;

            ctx.scratch.clearRetainingCapacity();
            ctx.scratch.appendSlice(ctx.allocator, trailing) catch return m.Error.OutOfMemory;
            return ctx.scratch.items;
        }

        /// Multi-row pick list. Copies the worker's response under a
        /// brief lock so the slice-of-slices we return is stable past
        /// the next worker write. Skips the entry the inline ghost
        /// would have shown (line 0 of res_buf) and dedupes via the
        /// shared `_lib.ListBuilder`.
        ///
        /// Storage: `rt.list_copy` is sized at `max_result`; `rt.list_slices`
        /// is sized at `list_count_max`. Both per-runtime so concurrent
        /// dispatch calls (none today, but the proxy might gain that
        /// later) wouldn't race.
        pub fn provideGhostList(rt: *Runtime, ctx: *m.Context) m.Error!?[]const []const u8 {
            if (ctx.line.uncertain) return null;
            const line = ctx.line.current();
            if (line.len == 0) return null;

            // Brief critical section: copy out the response. The slice
            // we return must outlive the lock; copying decouples us
            // from the worker's next write to `res_buf`.
            const copy_len = blk: {
                rt.shared.mutex.lockUncancelable(ctx.io);
                defer rt.shared.mutex.unlock(ctx.io);
                if (rt.shared.res_len == 0) break :blk 0;
                const n = rt.shared.res_len;
                @memcpy(rt.list_copy[0..n], rt.shared.res_buf[0..n]);
                break :blk n;
            };
            if (copy_len == 0) return null;

            const all = rt.list_copy[0..copy_len];
            // Inline ghost = first line of res_buf; skip it in the list.
            const inline_nl = std.mem.indexOfScalar(u8, all, '\n') orelse all.len;
            const inline_match = all[0..inline_nl];

            var builder = lib.ListBuilder(cfg.list_count_max){};
            var it = std.mem.splitScalar(u8, all, '\n');
            while (it.next()) |entry| {
                if (builder.full()) break;
                if (entry.len == 0) continue;
                if (entry.len <= line.len) continue;
                if (!std.mem.startsWith(u8, entry, line)) continue;
                _ = builder.tryAdd(entry, inline_match);
            }
            if (builder.len == 0) return null;

            // Spill into rt's persistent slice array so the returned
            // slice survives past the builder's stack frame.
            @memcpy(rt.list_slices[0..builder.len], builder.items());
            rt.list_slices_len = builder.len;
            return rt.list_slices[0..rt.list_slices_len];
        }

        pub fn onTick(rt: *Runtime, ctx: *m.Context, elapsed_ms: u64) m.Error!void {
            _ = elapsed_ms;
            if (cfg.suggestion_ttl_ms == 0) return; // timer disabled
            if (rt.last_keystroke_ms == 0) return;
            const now = nowMs();
            const idle = now - rt.last_keystroke_ms;
            if (idle <= 0) return;
            if (@as(u64, @intCast(idle)) < cfg.suggestion_ttl_ms) return;

            rt.shared.mutex.lockUncancelable(ctx.io);
            defer rt.shared.mutex.unlock(ctx.io);
            rt.shared.res_len = 0;
        }

        /// Fired by the dispatcher when the user presses Enter on a
        /// non-empty, certain line. We push it into the worker's
        /// single-slot record mailbox; the worker shells out to
        /// `atuin history start <cmd>` on its own thread so the proxy
        /// loop stays responsive.
        pub fn onLineCommit(rt: *Runtime, ctx: *m.Context, line: []const u8) m.Error!void {
            if (!cfg.record) return;
            if (line.len == 0 or line.len > cfg.max_query) return;

            // Capture the subprocess-aware cwd (or empty if at the
            // local prompt). Empty cwd → atuin uses its default
            // (process cwd). Non-empty → atuin records the entry with
            // the encoded URI as `cwd`, so [DIRECTORY] mode on Ctrl+R
            // naturally scopes per ssh/kubectl/etc. target.
            var cwd_scratch: [subprocess_mod.max_cwd_bytes]u8 = undefined;
            const resolved_cwd = ctx.subprocessCwd(&cwd_scratch, "");

            rt.shared.mutex.lockUncancelable(ctx.io);
            defer rt.shared.mutex.unlock(ctx.io);
            @memcpy(rt.shared.rec_buf[0..line.len], line);
            rt.shared.rec_len = line.len;
            if (resolved_cwd.len > 0 and resolved_cwd.len <= rt.shared.rec_cwd_buf.len) {
                @memcpy(rt.shared.rec_cwd_buf[0..resolved_cwd.len], resolved_cwd);
                rt.shared.rec_cwd_len = resolved_cwd.len;
            } else {
                rt.shared.rec_cwd_len = 0;
            }
            rt.shared.rec_pending = true;
            rt.shared.cv.signal(ctx.io);
        }

        /// Fired by Ctrl+Shift+D (default binding for
        /// `delete_history_match`). Shells out to atuin's
        /// `search --delete <query>`. Atuin v18 has no per-id delete
        /// and no exact-match search mode — but its **fuzzy mode
        /// supports fzf-style anchors**, so `^line$` is exact match.
        /// Default `cfg.delete_scope = .exact` uses that; the other
        /// scopes are opt-in and sweep wider.
        ///
        /// Runs synchronously on the proxy thread — a single
        /// std.process.run call, typically <200ms. Deliberate trade
        /// vs. routing through the worker mailbox: the user just
        /// pressed a deliberate key, the prompt is already cleared
        /// (the proxy sent Ctrl+U before calling us), so a brief
        /// blocking window is acceptable; the alternative is growing
        /// a third worker-mailbox slot.
        pub fn deleteHistoryMatch(rt: *Runtime, ctx: *m.Context, line: []const u8) m.Error!void {
            if (line.len == 0 or line.len > cfg.max_query) return;

            const search_arg: []const u8 = switch (cfg.delete_scope) {
                .exact, .fuzzy => "fuzzy",
                .prefix => "prefix",
                .full_text => "full-text",
            };
            const filter_arg = switch (cfg.filter_mode) {
                .global => "global",
                .host => "host",
                .session => "session",
                .directory => "directory",
            };

            // Build the query bytes. For .exact we wrap in `^...$` so
            // atuin's fuzzy matcher reads it as "starts AND ends with
            // this literal", which is the only CLI-accessible
            // exact-match. Buffer sits on the stack; max_query bounds
            // the size at comptime so the +2 anchor bytes are safe.
            var anchored_buf: [cfg.max_query + 2]u8 = undefined;
            const query: []const u8 = switch (cfg.delete_scope) {
                .exact => blk: {
                    anchored_buf[0] = '^';
                    @memcpy(anchored_buf[1 .. 1 + line.len], line);
                    anchored_buf[1 + line.len] = '$';
                    break :blk anchored_buf[0 .. line.len + 2];
                },
                else => line,
            };

            const argv = [_][]const u8{
                cfg.atuin_binary,
                "search",
                "--search-mode",
                search_arg,
                "--filter-mode",
                filter_arg,
                "--delete",
                query,
            };
            const result = std.process.run(rt.allocator, ctx.io, .{
                .argv = &argv,
                .stdout_limit = .limited(1024),
            }) catch return;
            rt.allocator.free(result.stdout);
            rt.allocator.free(result.stderr);
        }

        /// Status-bar segment. The runtime caches the rendered string
        /// so we don't reformat per render cycle.
        pub fn statusText(rt: *Runtime, ctx: *m.Context) m.Error!?[]const u8 {
            _ = ctx;
            _ = rt;
            // Static label for now — future: surface queued records,
            // last-sync age, sync-in-progress, etc.
            return "atuin";
        }
    };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

const test_io: std.Io = std.Io.failing;

test "configure exposes Runtime + hooks" {
    const A = configure(.{});
    try testing.expect(@hasDecl(A, "Runtime"));
    try testing.expect(@hasDecl(A, "onInput"));
    try testing.expect(@hasDecl(A, "provideGhostText"));
    try testing.expect(@hasDecl(A, "onTick"));
    try testing.expectEqualStrings("atuin", A.name);
}

test "configure with socket backend swaps the lookup arm" {
    const A = configure(.{ .backend = .socket, .socket_path = "/tmp/nope" });
    try testing.expect(A.config.backend == .socket);
}

test "configure carries delete_scope through to A.config (default exact)" {
    // Default is .exact so Ctrl+Shift+D only removes the typed line —
    // atuin's CLI has no exact-match search mode but fuzzy + `^...$`
    // anchors get us there. Test pins the surface so renames or
    // removals are caught here, not in the field.
    const A1 = configure(.{});
    try testing.expectEqual(DeleteScope.exact, A1.config.delete_scope);
    const A2 = configure(.{ .delete_scope = .prefix });
    try testing.expectEqual(DeleteScope.prefix, A2.config.delete_scope);
    const A3 = configure(.{ .delete_scope = .full_text });
    try testing.expectEqual(DeleteScope.full_text, A3.config.delete_scope);
    const A4 = configure(.{ .delete_scope = .fuzzy });
    try testing.expectEqual(DeleteScope.fuzzy, A4.config.delete_scope);
}

test "configure exposes provideGhostList hook (multi-row pick list)" {
    // The hook is required for the multi-suggestion feature to read
    // atuin entries. Without it the dispatcher's gatherGhostList
    // skips atuin and falls through to history — which means users
    // running `modules = .{ atuin, history }` (or atuin-only) would
    // see no pick list. Pin the surface so a future refactor that
    // removes the hook breaks `zig build test` instead of silently
    // breaking the feature.
    const A = configure(.{});
    try testing.expect(@hasDecl(A, "provideGhostList"));
}

test "configure exposes deleteHistoryMatch hook (regression: atuin-side delete must be wired)" {
    // Regression: the user had `modules = .{ guardrail, atuin, history }`
    // in their config and pressed Ctrl+Shift+D. The proxy walked the
    // dispatcher and only history's deleteHistoryMatch fired (atuin
    // didn't implement the hook at all), so the entry stayed in
    // atuin's daemon and re-suggested on the next prefix.
    //
    // After the fix, atuin advertises the hook → dispatcher fans the
    // call out to it. If this @hasDecl ever flips back to false the
    // delete is silently broken for everyone running atuin — fail
    // loudly here instead.
    const A = configure(.{});
    try testing.expect(@hasDecl(A, "deleteHistoryMatch"));
}
