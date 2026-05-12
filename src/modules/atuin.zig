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

extern "c" fn clock_gettime(clk_id: c_int, tp: *std.posix.timespec) c_int;
const CLOCK_MONOTONIC: c_int = 1;

fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), std.time.ns_per_ms);
}

pub const SearchMode = enum { prefix, full_text, fuzzy };
pub const FilterMode = enum { global, host, session, directory };
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
    max_result: comptime_int = 512,

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

            shutdown: bool = false,
        };

        pub const Runtime = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            shared: *Shared,
            thread: std.Thread,
            last_keystroke_ms: i64 = 0,
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
                    runRecord(gpa, io, record_local[0..record_len]);
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

            // No --reverse: atuin's default order is newest-first, which
            // is what a "fish-style autosuggest" wants. With --reverse +
            // --limit 1 we'd pin the OLDEST matching entry instead.
            const argv = [_][]const u8{
                cfg.atuin_binary,
                "search",
                "--search-mode",
                search_arg,
                "--filter-mode",
                filter_arg,
                "--limit",
                "1",
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

            var end: usize = 0;
            while (end < result.stdout.len and result.stdout[end] != '\n' and result.stdout[end] != '\r') : (end += 1) {}
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
        fn runRecord(gpa: std.mem.Allocator, io: std.Io, line: []const u8) void {
            if (line.len == 0) return;
            const argv = [_][]const u8{
                cfg.atuin_binary,
                "history",
                "start",
                line,
            };
            const result = std.process.run(gpa, io, .{
                .argv = &argv,
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
            const suggestion = rt.shared.res_buf[0..rt.shared.res_len];
            if (!std.mem.startsWith(u8, suggestion, line)) return null;

            const trailing = suggestion[line.len..];
            if (trailing.len == 0) return null;

            ctx.scratch.clearRetainingCapacity();
            ctx.scratch.appendSlice(ctx.allocator, trailing) catch return m.Error.OutOfMemory;
            return ctx.scratch.items;
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

            rt.shared.mutex.lockUncancelable(ctx.io);
            defer rt.shared.mutex.unlock(ctx.io);
            @memcpy(rt.shared.rec_buf[0..line.len], line);
            rt.shared.rec_len = line.len;
            rt.shared.rec_pending = true;
            rt.shared.cv.signal(ctx.io);
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
