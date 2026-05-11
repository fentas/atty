//! Atuin module — fish-style history autosuggestion as ghost text.
//!
//! Architecture:
//!
//!   main thread          shared (mutex)              worker thread
//!   ───────────          ──────────────              ─────────────
//!   onInput     ─────▶   req_buf  ──────────────▶   read latest
//!                        req_gen ↑                   run lookup
//!                                                    write result
//!                                                    res_buf  ◀────
//!                        res_gen ↑
//!   provideGhost ◀───    read res_buf
//!
//! One-slot mailbox: each new keystroke overwrites the pending query,
//! so the worker only ever sees the most recent state. No queue, no
//! backpressure.
//!
//! Backend selection is a comptime switch — the unused backend's code
//! is dropped from the binary entirely.

const std = @import("std");
const m = @import("../module.zig");

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
    /// Used only when backend == .socket.
    socket_path: []const u8 = "",
    /// Drop the suggestion if no keystroke has arrived for this many ms.
    /// Driven by onTick.
    suggestion_ttl_ms: u64 = 5_000,
    /// Maximum query / response size (kept comptime so we can size the
    /// shared mailbox as a value type, no allocation per request).
    max_query: comptime_int = 256,
    max_result: comptime_int = 512,
};

pub fn configure(comptime cfg: Config) type {
    return struct {
        pub const name = "atuin";
        pub const config = cfg;

        const Shared = struct {
            mutex: std.Thread.Mutex = .{},
            cv: std.Thread.Condition = .{},

            req_buf: [cfg.max_query]u8 = undefined,
            req_len: usize = 0,
            req_gen: u64 = 0,

            res_buf: [cfg.max_result]u8 = undefined,
            res_len: usize = 0,
            res_gen: u64 = 0,

            shutdown: bool = false,
        };

        pub const Runtime = struct {
            allocator: std.mem.Allocator,
            shared: *Shared,
            thread: std.Thread,
            /// Last time we saw a keystroke (millis since epoch).
            /// Drives the TTL — once we sit idle past suggestion_ttl_ms,
            /// onTick invalidates the cached suggestion so the proxy
            /// clears the overlay on the next render.
            last_keystroke_ms: i64 = 0,
        };

        pub fn attach(allocator: std.mem.Allocator) !Runtime {
            const shared = try allocator.create(Shared);
            shared.* = .{};
            errdefer allocator.destroy(shared);

            const thread = try std.Thread.spawn(.{}, worker, .{shared});
            return .{
                .allocator = allocator,
                .shared = shared,
                .thread = thread,
            };
        }

        pub fn detach(rt: *Runtime) void {
            {
                rt.shared.mutex.lock();
                defer rt.shared.mutex.unlock();
                rt.shared.shutdown = true;
                rt.shared.cv.signal();
            }
            rt.thread.join();
            rt.allocator.destroy(rt.shared);
        }

        // ---- worker -------------------------------------------------------

        fn worker(shared: *Shared) void {
            var query_local: [cfg.max_query]u8 = undefined;
            var query_len: usize = 0;
            var serving_gen: u64 = 0;

            while (true) {
                shared.mutex.lock();
                while (!shared.shutdown and shared.req_gen == serving_gen) {
                    shared.cv.wait(&shared.mutex);
                }
                if (shared.shutdown) {
                    shared.mutex.unlock();
                    return;
                }
                serving_gen = shared.req_gen;
                query_len = shared.req_len;
                @memcpy(query_local[0..query_len], shared.req_buf[0..query_len]);
                shared.mutex.unlock();

                var result_buf: [cfg.max_result]u8 = undefined;
                const maybe_n = lookup(query_local[0..query_len], &result_buf) catch null;

                shared.mutex.lock();
                if (maybe_n) |n| {
                    @memcpy(shared.res_buf[0..n], result_buf[0..n]);
                    shared.res_len = n;
                } else {
                    shared.res_len = 0;
                }
                shared.res_gen = serving_gen;
                shared.mutex.unlock();
            }
        }

        // ---- backends -----------------------------------------------------

        fn lookup(query: []const u8, out: []u8) !?usize {
            if (query.len == 0) return null;
            return switch (cfg.backend) {
                .subprocess => subprocessLookup(query, out),
                .socket => socketLookup(query, out),
            };
        }

        fn subprocessLookup(query: []const u8, out: []u8) !?usize {
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

            // Per-lookup arena: the child Process API needs an allocator,
            // but everything we hand it lives only for the duration of
            // this call. No long-lived heap use.
            var arena_buf: [4096]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
            const allocator = fba.allocator();

            var child = std.process.Child.init(&.{
                cfg.atuin_binary,
                "search",
                "--search-mode",
                search_arg,
                "--filter-mode",
                filter_arg,
                "--limit",
                "1",
                "--cmd-only",
                "--reverse",
                query,
            }, allocator);
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Ignore;

            child.spawn() catch return null;
            defer _ = child.kill() catch {};

            const stdout = child.stdout orelse return null;
            var buf: [cfg.max_result]u8 = undefined;
            const n = stdout.readAll(&buf) catch 0;
            _ = child.wait() catch {};

            if (n == 0) return null;

            var end: usize = 0;
            while (end < n and buf[end] != '\n' and buf[end] != '\r') : (end += 1) {}
            if (end == 0) return null;
            if (end > out.len) end = out.len;
            @memcpy(out[0..end], buf[0..end]);
            return end;
        }

        fn socketLookup(query: []const u8, out: []u8) !?usize {
            _ = query;
            _ = out;
            // TODO: implement once Atuin's IPC protocol stabilises.
            return null;
        }

        // ---- hooks --------------------------------------------------------

        pub fn onInput(
            rt: *Runtime,
            ctx: *m.Context,
            input: []const u8,
        ) m.Error!m.Action {
            _ = input;
            rt.last_keystroke_ms = std.time.milliTimestamp();

            const line = ctx.line.current();
            if (ctx.line.uncertain or line.len == 0 or line.len > cfg.max_query) {
                return .forward;
            }

            rt.shared.mutex.lock();
            defer rt.shared.mutex.unlock();
            @memcpy(rt.shared.req_buf[0..line.len], line);
            rt.shared.req_len = line.len;
            rt.shared.req_gen +%= 1;
            rt.shared.cv.signal();
            return .forward;
        }

        pub fn provideGhostText(rt: *Runtime, ctx: *m.Context) m.Error!?[]const u8 {
            if (ctx.line.uncertain) return null;
            const line = ctx.line.current();
            if (line.len == 0) return null;

            rt.shared.mutex.lock();
            defer rt.shared.mutex.unlock();

            if (rt.shared.res_len == 0) return null;
            const suggestion = rt.shared.res_buf[0..rt.shared.res_len];
            if (!std.mem.startsWith(u8, suggestion, line)) return null;

            const trailing = suggestion[line.len..];
            if (trailing.len == 0) return null;

            ctx.scratch.clearRetainingCapacity();
            ctx.scratch.appendSlice(trailing) catch return m.Error.OutOfMemory;
            return ctx.scratch.items;
        }

        /// Drop the cached suggestion once it goes stale. The proxy
        /// will see provideGhostText return null next render cycle and
        /// wipe the overlay.
        pub fn onTick(rt: *Runtime, ctx: *m.Context, elapsed_ms: u64) m.Error!void {
            _ = ctx;
            _ = elapsed_ms;
            if (rt.last_keystroke_ms == 0) return;
            const now = std.time.milliTimestamp();
            const idle = now - rt.last_keystroke_ms;
            if (idle <= 0) return;
            if (@as(u64, @intCast(idle)) < cfg.suggestion_ttl_ms) return;

            rt.shared.mutex.lock();
            defer rt.shared.mutex.unlock();
            rt.shared.res_len = 0;
        }
    };
}

// ===========================================================================
// Tests — exercise the static surface; the worker thread + subprocess
// path is covered by the integration test.
// ===========================================================================

const testing = std.testing;

test "configure with default config compiles and exposes Runtime" {
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

test "subprocessLookup returns null on missing binary" {
    const A = configure(.{ .atuin_binary = "/path/does/not/exist" });
    var out: [256]u8 = undefined;
    const got = try A.subprocessLookup("ls", &out);
    try testing.expect(got == null);
}

test "attach / detach lifecycle" {
    const A = configure(.{});
    var rt = try A.attach(testing.allocator);
    A.detach(&rt);
}
