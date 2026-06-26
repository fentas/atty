//! atty benchmark harness — Tier A in-process microbenchmarks.
//!
//! Times the per-keystroke hot path and prints `ns/op` plus the number
//! of heap allocations per op — the latter defends atty's
//! zero-allocation-hot-path claim (a non-zero count is a regression).
//!
//!     zig build bench -Doptimize=ReleaseFast
//!     zig build bench -Doptimize=ReleaseFast -- --json
//!     zig build bench -Doptimize=ReleaseFast -- --filter dispatch
//!
//! Build in a Release mode — Debug numbers are meaningless (the harness
//! warns when run unoptimised). See docs/benchmarking.md for the plan,
//! including the Tier-B (sandbox/eBPF) benchmarks that live elsewhere.

const std = @import("std");
const builtin = @import("builtin");
const atty = @import("atty");

const Dispatcher = atty.dispatch.Dispatcher;
const Context = atty.module.Context;
const LineState = atty.line_state.LineState;

// Module tuple under test — the dependency-free default. History gives
// the ghost-text path something to scan. Add/remove modules here to
// profile other compositions; the harness is composition-agnostic.
const bench_modules = .{
    atty.modules.guardrail.configure(.{}),
    atty.modules.history.configure(.{}),
};
const D = Dispatcher(bench_modules);

// ── Counting allocator ──────────────────────────────────────────────
// Wraps a backing allocator and tallies alloc CALLS so a benchmark can
// assert the hot path made zero heap requests. We measure the delta
// across the timed loop (after warm-up), so one-time setup allocations
// don't count against the per-op figure.
const Counting = struct {
    backing: std.mem.Allocator,
    count: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
    fn alloc(p: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(p));
        self.count += 1;
        return self.backing.rawAlloc(len, a, ra);
    }
    fn resize(p: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(p));
        return self.backing.rawResize(mem, a, new_len, ra);
    }
    fn remap(p: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(p));
        return self.backing.rawRemap(mem, a, new_len, ra);
    }
    fn free(p: *anyopaque, mem: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(p));
        self.backing.rawFree(mem, a, ra);
    }
};

// Monotonic clock in ns — `std.time.Timer` isn't in this Zig; mirror
// the libc path the rest of the codebase uses (src/modules/_lib.zig).
fn nowNs() i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

const Result = struct {
    name: []const u8,
    ns_per_op: f64,
    allocs_per_op: f64,
    note: []const u8 = "",
};

// Shared per-run state handed to each benchmark body.
const Env = struct {
    rts: *D.Runtimes,
    ctx: *Context,
    line: *LineState,
    counting: *Counting,
};

const Bench = struct {
    name: []const u8,
    warmup: usize,
    iters: usize,
    run: *const fn (env: *Env, iters: usize) void,
};

fn timeBench(env: *Env, b: Bench) Result {
    b.run(env, b.warmup); // warm caches; absorb one-time setup allocs
    const before = env.counting.count;
    const t0 = nowNs();
    b.run(env, b.iters);
    const elapsed: f64 = @floatFromInt(nowNs() - t0);
    const allocs = env.counting.count - before;
    const iters_f: f64 = @floatFromInt(b.iters);
    return .{
        .name = b.name,
        .ns_per_op = elapsed / iters_f,
        .allocs_per_op = @as(f64, @floatFromInt(allocs)) / iters_f,
    };
}

// ── Benchmark bodies ────────────────────────────────────────────────

fn runDispatchInput(env: *Env, iters: usize) void {
    // The per-keystroke hot path: feed a printable byte through the
    // module chain. `applyInput` mirrors the proxy updating its line
    // model before dispatch. doNotOptimizeAway keeps ReleaseFast from
    // deleting the work we're timing.
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        std.mem.doNotOptimizeAway(env.line.applyInput("a"));
        const act = D.dispatchInput(env.rts, env.ctx, "a") catch atty.module.Action.forward;
        std.mem.doNotOptimizeAway(act);
    }
}

fn runLineState(env: *Env, iters: usize) void {
    // Pure line-model update over a rotating mix of printable + CSI.
    const samples = [_][]const u8{ "g", "i", "t", " ", "s", "\x1b[D", "\x1b[C", "\x08" };
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        std.mem.doNotOptimizeAway(env.line.applyInput(samples[i % samples.len]));
    }
}

fn runGhostText(env: *Env, iters: usize) void {
    // Ghost suggestion lookup. Best-effort: with an empty history ring
    // this measures the fast null path; with a populated one it measures
    // the prefix scan. (The harness pre-seeds a `gi` prefix in main.)
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const g = D.gatherGhostText(env.rts, env.ctx) catch null;
        std.mem.doNotOptimizeAway(g);
    }
}

const benches = [_]Bench{
    .{ .name = "dispatch_input", .warmup = 10_000, .iters = 1_000_000, .run = runDispatchInput },
    .{ .name = "line_state_apply", .warmup = 10_000, .iters = 1_000_000, .run = runLineState },
    .{ .name = "ghost_text", .warmup = 1_000, .iters = 200_000, .run = runGhostText },
};

// ── Main ────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var json = false;
    var filter_buf: [128]u8 = undefined;
    var filter: ?[]const u8 = null;
    {
        var it = try init.minimal.args.iterateAllocator(gpa);
        defer it.deinit();
        _ = it.next(); // argv[0]
        while (it.next()) |a| {
            if (std.mem.eql(u8, a, "--json")) {
                json = true;
            } else if (std.mem.eql(u8, a, "--filter")) {
                if (it.next()) |f| {
                    // Copy out — the iterator frees its buffer on deinit.
                    const n = @min(f.len, filter_buf.len);
                    @memcpy(filter_buf[0..n], f[0..n]);
                    filter = filter_buf[0..n];
                }
            }
        }
    }

    if (builtin.mode == .Debug) {
        std.debug.print(
            "warning: built in Debug — numbers are not representative. " ++
                "Re-run with -Doptimize=ReleaseFast.\n\n",
            .{},
        );
    }

    var counting: Counting = .{ .backing = gpa };
    const alloc = counting.allocator();

    var rts = try D.attachAll(alloc, io);
    defer D.detachAll(alloc, io, &rts);

    var line: LineState = .{};
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(alloc);
    // Seed a prefix so the ghost-text scan has something to match.
    _ = line.applyInput("gi");

    var ctx: Context = .{
        .allocator = alloc,
        .io = io,
        .line = &line,
        .scratch = &scratch,
        .is_tty = false,
    };

    var env: Env = .{ .rts = &rts, .ctx = &ctx, .line = &line, .counting = &counting };

    var results: [benches.len]Result = undefined;
    var n: usize = 0;
    for (benches) |b| {
        if (filter) |f| {
            if (std.mem.indexOf(u8, b.name, f) == null) continue;
        }
        results[n] = timeBench(&env, b);
        n += 1;
    }

    if (json) {
        std.debug.print("[", .{});
        for (results[0..n], 0..) |r, i| {
            std.debug.print(
                "{s}{{\"name\":\"{s}\",\"ns_per_op\":{d:.2},\"allocs_per_op\":{d:.4}}}",
                .{ if (i == 0) "" else ",", r.name, r.ns_per_op, r.allocs_per_op },
            );
        }
        std.debug.print("]\n", .{});
    } else {
        std.debug.print("atty bench — {s}\n", .{@tagName(builtin.mode)});
        std.debug.print("{s:<20} {s:>12} {s:>12}\n", .{ "benchmark", "ns/op", "allocs/op" });
        std.debug.print("{s:-<46}\n", .{""});
        for (results[0..n]) |r| {
            std.debug.print("{s:<20} {d:>12.1} {d:>12.4}\n", .{ r.name, r.ns_per_op, r.allocs_per_op });
        }
    }
}
