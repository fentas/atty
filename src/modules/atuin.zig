//! Atuin module — fish-style history autosuggestion as ghost text,
//! plus manual command recording (since the shell plugin is opt-in and
//! requires ble.sh on bash). atty doing the recording itself means the
//! shell stays vanilla.
//!
//! Architecture (latest-wins mailbox for query, bounded FIFO ring
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
//!   onLineCommit ───▶    rec_queue[tail] ───────▶   drain head, FIFO
//!                        rec_count ↑                 run record
//!                                                    maybe run sync
//!
//! Records use a bounded FIFO instead of a single
//! latest-wins slot so a burst of Enter-presses preserves all
//! commits. At cap the producer drops the NEWEST commit and bumps
//! `rec_dropped`; the oldest is already in flight to atuin's local
//! store and shouldn't be sacrificed for a later one.
//!
//! "Sync" here means firing `atuin sync` from the worker after either
//! `sync_after_records` commits or `sync_interval_ms` of wall time,
//! whichever is sooner. The CLI is the source of truth — we never
//! touch atuin's sqlite directly. One final sync runs on detach
//! (BLOCKING up to `sync_on_detach_timeout_ms`)
//! so an interactive session always flushes before exit.

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
    /// Bounded record queue depth. The committed-
    /// command path now uses FIFO semantics so two Enters arriving
    /// before the worker drains don't lose the first. At cap, the
    /// newest commit is dropped + `rec_dropped` surfaces in the
    /// status bar as `atuin (N dropped)`. Per-slot footprint at
    /// defaults is max_query (256) + max_cwd (1024) + intent (256)
    /// + author tag = ~1552 B; default 16 ≈ 25 KB. Compile-time
    /// asserted ≥ 2 — capacity 1 would collapse to latest-wins.
    record_queue_capacity: comptime_int = 16,
    /// Fire `atuin sync` after this many recorded commits (per session).
    /// 0 disables the count-based trigger.
    sync_after_records: u32 = 10,
    /// Fire `atuin sync` after this many ms since the previous sync.
    /// 0 disables the time-based trigger.
    sync_interval_ms: u64 = 60_000,
    /// Run one final `atuin sync` on detach if we recorded anything.
    /// the detach path waits for this sync to
    /// complete (blocking, up to `sync_on_detach_timeout_ms`) so the
    /// promised final flush isn't killed by process exit. Periodic
    /// syncs during normal operation stay detached.
    sync_on_detach: bool = true,
    /// Hard cap on how long the detach blocks waiting for the final
    /// `atuin sync`. The sync runs on a joined
    /// thread; if it doesn't finish in this window, the proxy exits
    /// without waiting further. Atuin's offline backoff can hang
    /// indefinitely on a saturated NIC — the cap keeps shutdown
    /// bounded. 0 disables the timeout (block until completion).
    sync_on_detach_timeout_ms: u64 = 3_000,

    /// Scope of the `deleteHistoryMatch` (Ctrl+Shift+D) action against
    /// atuin's database. Default `.exact` uses atuin's fuzzy mode
    /// with fzf-style `^...$` anchors so only commands *equal* to
    /// the line are removed. See `DeleteScope` for the broader modes
    /// if you want Ctrl+Shift+D to sweep wider.
    delete_scope: DeleteScope = .exact,

    /// Tag LLM-authored commits with `atuin history start --author
    /// <prefix>:llm <cmd>`. Off by default because not every atuin
    /// build accepts `--author` (the flag landed in v18.3+) and
    /// passing an unknown flag aborts the record. Turn on once you
    /// confirm your atuin supports it; then `atuin search
    /// --filter-mode global --author <prefix>:llm` will scope to
    /// model-suggested commits. User-typed commits stay untagged
    /// to preserve the existing on-disk format.
    tag_llm_author: bool = false,

    /// Prefix prepended to the author tag (`<prefix>:llm`). Lets
    /// multiple atty installs distinguish each other in shared
    /// atuin databases. Common choices: `"atty"`, `"<hostname>"`,
    /// `"<user>@<host>"`.
    author_tag_prefix: []const u8 = "atty",

    /// Pass `--intent "<description>"` when recording an
    /// LLM-authored commit (paired with `--author`). The intent
    /// text comes from the LLM's `description` field on the
    /// dialog `.exec` reply — staged onto `LineState` via
    /// `setCommitIntent` at the same moment as the author tag,
    /// snapshot at submit time, read here. Off by default because
    /// `--intent` landed even later than `--author` (atuin
    /// v18.5+); passing an unknown flag aborts the record. Turn
    /// on once you confirm your atuin supports it. User-typed
    /// commits have no intent to record so this is a no-op for
    /// them either way.
    tag_llm_intent: bool = false,
};

pub fn configure(comptime cfg: Config) type {
    // a 0-capacity FIFO would underflow the
    // `(idx + 1) % 0` modulo. Catch the misconfiguration at
    // compile time. Capacity 1 collapses to drop-newest-on-second-
    // push but is a legal degenerate; require at least 2 for FIFO
    // semantics to hold (otherwise consumers expecting "preserves
    // burst of 2 commits" see the prior latest-wins shape).
    comptime {
        if (cfg.record_queue_capacity < 2) {
            @compileError("atuin: record_queue_capacity must be >= 2 — use the default (16) or pick a higher value");
        }
    }
    return struct {
        pub const name = "atuin";
        pub const config = cfg;

        pub const RecordSlot = struct {
            cmd_buf: [cfg.max_query]u8 = undefined,
            cmd_len: usize = 0,
            cwd_buf: [subprocess_mod.max_cwd_bytes]u8 = undefined,
            cwd_len: usize = 0,
            author: m.Author = .user,
            intent_buf: [256]u8 = undefined,
            intent_len: usize = 0,
        };

        pub const Shared = struct {
            mutex: std.Io.Mutex = .init,
            cv: std.Io.Condition = .init,

            req_buf: [cfg.max_query]u8 = undefined,
            req_len: usize = 0,
            req_gen: u64 = 0,

            res_buf: [cfg.max_result]u8 = undefined,
            res_len: usize = 0,
            res_gen: u64 = 0,

            // FIFO ring buffer of pending records.
            // Replaces the prior single-slot latest-wins mailbox so
            // bursts of commits (paste, automation, LLM-assisted
            // submits) preserve all entries in order. At cap, the
            // producer drops the newest commit and bumps
            // `rec_dropped` so the worker / status bar can surface
            // the loss instead of silently swallowing it.
            //
            // Indices: head = next slot the worker drains; tail =
            // next slot the producer fills. Full when count ==
            // capacity; empty when count == 0.
            rec_queue: [cfg.record_queue_capacity]RecordSlot = undefined,
            rec_head: usize = 0,
            rec_tail: usize = 0,
            rec_count: usize = 0,
            rec_dropped: u32 = 0,

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
            /// Buffer for `statusText`'s formatted output when
            /// `rec_dropped > 0`. Bounded — the
            /// longest expected string is `atuin (4294967295 dropped)`
            /// = 26 chars.
            status_buf: [32]u8 = undefined,
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

            var record_local: RecordSlot = .{};
            var records_since_sync: u32 = 0;
            var last_sync_ms: i64 = 0;
            var total_records: u32 = 0;

            while (true) {
                shared.mutex.lockUncancelable(io);
                while (!shared.shutdown and
                    shared.req_gen == serving_gen and
                    shared.rec_count == 0)
                {
                    shared.cv.waitUncancelable(io, &shared.mutex);
                }
                if (shared.shutdown) {
                    // Drain any queued records BEFORE the final
                    // sync so a burst of commits in the last 50ms
                    // doesn't vanish (subagent round-1 finding —
                    // checking shutdown before the drain dropped
                    // in-flight records, contradicting #027's
                    // "preserves all commits" claim). Pop slots
                    // under the lock into a local buffer, release,
                    // then `runRecord` each without the lock held.
                    var drain_local: [cfg.record_queue_capacity]RecordSlot = undefined;
                    var drain_n: usize = 0;
                    while (shared.rec_count > 0 and drain_n < drain_local.len) {
                        drain_local[drain_n] = shared.rec_queue[shared.rec_head];
                        shared.rec_head = (shared.rec_head + 1) % cfg.record_queue_capacity;
                        shared.rec_count -= 1;
                        drain_n += 1;
                    }
                    shared.mutex.unlock(io);
                    if (cfg.record) {
                        var i: usize = 0;
                        while (i < drain_n) : (i += 1) {
                            const s = &drain_local[i];
                            const intent_slice: ?[]const u8 = if (s.intent_len > 0)
                                s.intent_buf[0..s.intent_len]
                            else
                                null;
                            runRecord(
                                gpa,
                                io,
                                s.cmd_buf[0..s.cmd_len],
                                s.cwd_buf[0..s.cwd_len],
                                s.author,
                                intent_slice,
                            );
                            total_records += 1;
                        }
                    }
                    // BLOCKING final sync so the
                    // promised flush actually lands. main.zig calls
                    // std.process.exit immediately after proxy.run
                    // returns; the previous `runSync` detached the
                    // sync thread and let the OS kill it mid-flight.
                    // `runSyncBlocking` joins (with timeout) so we
                    // either succeed or give up explicitly.
                    if (cfg.record and cfg.sync_on_detach and total_records > 0)
                        runSyncBlocking(gpa, io);
                    return;
                }

                const has_query = shared.req_gen != serving_gen;
                if (has_query) {
                    serving_gen = shared.req_gen;
                    query_len = shared.req_len;
                    @memcpy(query_local[0..query_len], shared.req_buf[0..query_len]);
                }

                // drain one record from the FIFO
                // head. Keep the drain to one-per-loop iteration so
                // bursts of records don't starve query handling
                // (the cv signals once per producer event; we still
                // process queries in the same wakeup).
                const has_record = shared.rec_count > 0;
                if (has_record) {
                    record_local = shared.rec_queue[shared.rec_head];
                    shared.rec_head = (shared.rec_head + 1) % cfg.record_queue_capacity;
                    shared.rec_count -= 1;
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
                    const intent_slice: ?[]const u8 = if (record_local.intent_len > 0)
                        record_local.intent_buf[0..record_local.intent_len]
                    else
                        null;
                    runRecord(
                        gpa,
                        io,
                        record_local.cmd_buf[0..record_local.cmd_len],
                        record_local.cwd_buf[0..record_local.cwd_len],
                        record_local.author,
                        intent_slice,
                    );
                    total_records += 1;
                    records_since_sync += 1;
                    const now = nowMs();
                    // start the sync clock on the
                    // first recorded command WITHOUT also firing a
                    // sync there. Prior shape included `last_sync_ms
                    // == 0` as an unconditional trigger, so every
                    // session synced after record #1 regardless of
                    // the operator's `sync_after_records` /
                    // `sync_interval_ms` thresholds.
                    if (last_sync_ms == 0) {
                        last_sync_ms = now;
                    }
                    const count_due = cfg.sync_after_records > 0 and
                        records_since_sync >= cfg.sync_after_records;
                    const time_due = cfg.sync_interval_ms > 0 and
                        @as(u64, @intCast(now - last_sync_ms)) >= cfg.sync_interval_ms;
                    if (count_due or time_due) {
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
        /// Comptime-formatted author tag — every byte is known at
        /// configure() time, no runtime buffer.
        const author_tag_llm: []const u8 =
            std.fmt.comptimePrint("{s}:llm", .{cfg.author_tag_prefix});

        /// Pure argv builder, factored out of `runRecord` so the
        /// flag/author/intent/cwd interactions can be unit-tested
        /// without spawning a subprocess. Caller supplies the
        /// `[10][]const u8` scratch buffer; we return the populated
        /// subslice. Slot budget: 3 fixed (binary/history/start) +
        /// 2 (--cwd <v>) + 2 (--author <v>) + 2 (--intent <v>) + 1
        /// (line) = 10.
        pub fn buildRecordArgv(
            buf: *[10][]const u8,
            line: []const u8,
            cwd: []const u8,
            author: m.Author,
            intent: ?[]const u8,
        ) []const []const u8 {
            var n: usize = 0;
            buf[n] = cfg.atuin_binary;
            n += 1;
            buf[n] = "history";
            n += 1;
            buf[n] = "start";
            n += 1;
            if (cwd.len > 0) {
                buf[n] = "--cwd";
                n += 1;
                buf[n] = cwd;
                n += 1;
            }
            if (cfg.tag_llm_author and author == .llm) {
                buf[n] = "--author";
                n += 1;
                buf[n] = author_tag_llm;
                n += 1;
            }
            if (cfg.tag_llm_intent and author == .llm) {
                if (intent) |intent_text| if (intent_text.len > 0) {
                    buf[n] = "--intent";
                    n += 1;
                    buf[n] = intent_text;
                    n += 1;
                };
            }
            buf[n] = line;
            n += 1;
            return buf[0..n];
        }

        fn runRecord(
            gpa: std.mem.Allocator,
            io: std.Io,
            line: []const u8,
            cwd: []const u8,
            author: m.Author,
            intent: ?[]const u8,
        ) void {
            if (line.len == 0) return;
            var argv_buf: [10][]const u8 = undefined;
            const argv = buildRecordArgv(&argv_buf, line, cwd, author, intent);
            const result = std.process.run(gpa, io, .{
                .argv = argv,
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

        /// blocking final-sync path used by worker
        /// shutdown. Spawns the sync on a JOINED thread (not detached)
        /// so the proxy waits for completion before main.zig hits
        /// `std.process.exit`. Capped at `cfg.sync_on_detach_timeout_ms`
        /// to keep shutdown bounded — atuin's offline backoff can
        /// hang on a saturated NIC.
        ///
        /// The timeout is implemented via a sentinel flag + poll
        /// loop rather than `std.Thread.timedJoin` because zig 0.16
        /// stdlib doesn't expose a portable join-with-timeout.
        /// Polling overhead is bounded by `poll_step_ms` × iterations;
        /// on success the thread joins cleanly, on timeout we LEAK
        /// the thread (it will continue and eventually exit when
        /// the process does or when atuin returns).
        fn runSyncBlocking(gpa: std.mem.Allocator, io: std.Io) void {
            const SyncDone = struct {
                flag: std.atomic.Value(bool) = .init(false),
                gpa: std.mem.Allocator,
                io: std.Io,
                fn run(self: *@This()) void {
                    syncOnThread(self.gpa, self.io);
                    self.flag.store(true, .release);
                }
            };
            // Allocated on heap so a leaked thread (timeout path)
            // keeps a valid pointer to its flag until it sets it.
            const done = gpa.create(SyncDone) catch return;
            done.* = .{ .gpa = gpa, .io = io };

            const t = std.Thread.spawn(.{}, SyncDone.run, .{done}) catch {
                gpa.destroy(done);
                return;
            };

            if (cfg.sync_on_detach_timeout_ms == 0) {
                // No timeout — wait forever (or until sync completes).
                t.join();
                gpa.destroy(done);
                return;
            }

            const start = nowMs();
            const deadline_ms: i64 = start + @as(i64, @intCast(cfg.sync_on_detach_timeout_ms));
            // 10 ms poll step. nanosleep matches the pattern in
            // src/modules/llm/worker.zig — zig 0.16 stdlib doesn't
            // expose a portable timed-sleep so we go via libc.
            const sleep_ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
            while (nowMs() < deadline_ms) {
                if (done.flag.load(.acquire)) {
                    t.join();
                    gpa.destroy(done);
                    return;
                }
                _ = std.c.nanosleep(&sleep_ts, null);
            }
            // Deadline expired. Re-check the flag once more before
            // committing to the leak path — a sync that completed
            // between the last load and the deadline check is
            // perfectly joinable (subagent round-1 race finding).
            if (done.flag.load(.acquire)) {
                t.join();
                gpa.destroy(done);
                return;
            }
            // Timeout: leak the thread + heap done (it'll set the
            // flag and exit on its own when sync completes; we just
            // can't reclaim it without blocking past the deadline).
            t.detach();
            // `done` is intentionally NOT destroyed — the leaked
            // thread still owns a pointer to it. The struct is
            // ~40-64 bytes (AtomicValue(bool) + std.mem.Allocator
            // + std.Io); we leak at most once per session.
            // Acceptable for an interactive tool's shutdown path —
            // the process exits shortly after either way.
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
        /// non-empty, certain line. We push it onto the worker's bounded
        /// FIFO record queue (`rec_queue`, capacity
        /// `record_queue_capacity`); the worker drains it head-first and
        /// shells out to `atuin history start <cmd>` on its own thread so
        /// the proxy loop stays responsive.
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
            const intent = ctx.line.committedIntent();
            const author = ctx.line.committedAuthor();

            pushRecord(rt.shared, ctx.io, line, resolved_cwd, author, intent);
        }

        /// Test-visible push helper — FIFO ring
        /// push. Returns no value; overflow bumps `rec_dropped`
        /// silently (caller-side error handling would just discard
        /// the line anyway). Drop-newest on overflow because the
        /// oldest record is presumably already enroute to atuin's
        /// local store via the worker's drain; the new arrival is
        /// the one in jeopardy. Holds `shared.mutex` for the full
        /// push so a concurrent worker drain sees a consistent
        /// head/tail/count triple.
        pub fn pushRecord(
            shared: *Shared,
            io: std.Io,
            line: []const u8,
            cwd: []const u8,
            author: m.Author,
            intent: ?[]const u8,
        ) void {
            shared.mutex.lockUncancelable(io);
            defer shared.mutex.unlock(io);
            if (shared.rec_count >= cfg.record_queue_capacity) {
                shared.rec_dropped +%= 1;
                return;
            }
            const slot = &shared.rec_queue[shared.rec_tail];
            @memcpy(slot.cmd_buf[0..line.len], line);
            slot.cmd_len = line.len;
            if (cwd.len > 0 and cwd.len <= slot.cwd_buf.len) {
                @memcpy(slot.cwd_buf[0..cwd.len], cwd);
                slot.cwd_len = cwd.len;
            } else {
                slot.cwd_len = 0;
            }
            slot.author = author;
            if (intent) |intent_text| {
                const n = @min(intent_text.len, slot.intent_buf.len);
                @memcpy(slot.intent_buf[0..n], intent_text[0..n]);
                slot.intent_len = n;
            } else {
                slot.intent_len = 0;
            }
            shared.rec_tail = (shared.rec_tail + 1) % cfg.record_queue_capacity;
            shared.rec_count += 1;
            shared.cv.signal(io);
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

        /// Status-bar segment. Defaults to the bare `atuin` label;
        /// if any committed records were dropped because the FIFO
        /// hit cap, append `(N dropped)` so the
        /// operator notices their commits aren't being recorded.
        /// Cleared back to `atuin` only on detach — the count is
        /// session-cumulative because there's no obvious "ack" event
        /// from the operator side.
        pub fn statusText(rt: *Runtime, ctx: *m.Context) m.Error!?[]const u8 {
            _ = ctx;
            rt.shared.mutex.lockUncancelable(rt.io);
            const dropped = rt.shared.rec_dropped;
            rt.shared.mutex.unlock(rt.io);
            if (dropped == 0) return "atuin";
            // Format into the runtime's status_buf so the returned
            // slice survives until the next statusText call.
            const written = std.fmt.bufPrint(
                &rt.status_buf,
                "atuin ({d} dropped)",
                .{dropped},
            ) catch return "atuin";
            return written;
        }
    };
}

// ===========================================================================
// Tests — extracted to `atuin_tests.zig` for readability.
// ===========================================================================

test {
    _ = @import("atuin_tests.zig");
}
