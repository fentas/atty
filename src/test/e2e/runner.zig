//! e2e scenario runner.
//!
//! Discovers `tests/e2e/<name>/scenario.e2e` files and executes each.
//! Each scenario produces:
//!   golden/env.toml
//!   golden/cast.json
//!   golden/<snap_name>/grid.txt
//!   golden/<snap_name>/grid.sgr
//!
//! Modes:
//!   normal (default) — compare each snapshot to the existing golden; fail on diff
//!   --update         — overwrite goldens unconditionally
//!
//! Usage:
//!   atty-e2e [--update] [--filter <substr>] --bin <atty-path> <tests-dir>

const std = @import("std");
const dsl = @import("dsl.zig");
const vt = @import("vt.zig");
const harness = @import("harness.zig");
const snapshot = @import("snapshot.zig");
const atty = @import("atty");

const Allocator = std.mem.Allocator;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

const Args = struct {
    update: bool = false,
    filter: ?[]const u8 = null,
    atty_bin: ?[]const u8 = null,
    tests_dir: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var arg_it = try init.minimal.args.iterateAllocator(gpa);
    defer arg_it.deinit();
    _ = arg_it.next(); // argv0

    var parsed: Args = .{};
    while (arg_it.next()) |a| {
        if (std.mem.eql(u8, a, "--update") or std.mem.eql(u8, a, "-u")) {
            parsed.update = true;
        } else if (std.mem.eql(u8, a, "--filter")) {
            parsed.filter = arg_it.next() orelse return die("--filter needs a value");
        } else if (std.mem.eql(u8, a, "--bin")) {
            parsed.atty_bin = arg_it.next() orelse return die("--bin needs a path");
        } else if (a[0] == '-') {
            return die("unknown flag");
        } else {
            parsed.tests_dir = a;
        }
    }

    const tests_dir = parsed.tests_dir orelse "tests/e2e";
    const atty_bin = parsed.atty_bin orelse "zig-out/bin/atty";

    // Honour env-based override for `ATTY_E2E_UPDATE=1 make e2e` ergonomics.
    if (getenv("ATTY_E2E_UPDATE")) |raw| {
        const v = std.mem.sliceTo(raw, 0);
        if (std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true")) parsed.update = true;
    }

    // Verify atty binary exists.
    var cwd = std.Io.Dir.cwd();
    cwd.access(io, atty_bin, .{}) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: atty binary not found at {s}\n", .{atty_bin}) catch "error\n";
        _ = std.c.write(2, msg.ptr, msg.len);
        std.process.exit(2);
    };

    // Discover scenarios.
    var scenarios: std.ArrayList(Scenario) = .empty;
    defer {
        for (scenarios.items) |*s| s.deinit(gpa);
        scenarios.deinit(gpa);
    }
    try discoverScenarios(io, gpa, tests_dir, &scenarios);
    if (scenarios.items.len == 0) {
        std.debug.print("(no scenarios under {s})\n", .{tests_dir});
        return;
    }

    var pass: u32 = 0;
    var fail: u32 = 0;
    var updated: u32 = 0;

    for (scenarios.items) |sc| {
        if (parsed.filter) |f| {
            if (std.mem.indexOf(u8, sc.name, f) == null) continue;
        }
        const result = runScenario(io, gpa, sc, atty_bin, parsed.update) catch |e| {
            std.debug.print("  {s}: ERROR {t}\n", .{ sc.name, e });
            fail += 1;
            continue;
        };
        switch (result) {
            .pass => {
                std.debug.print("  {s}: PASS\n", .{sc.name});
                pass += 1;
            },
            .updated => {
                std.debug.print("  {s}: UPDATED\n", .{sc.name});
                updated += 1;
            },
            .fail => |why| {
                std.debug.print("  {s}: FAIL — {s}\n", .{ sc.name, why });
                fail += 1;
            },
        }
    }

    std.debug.print("\ne2e: {d} pass, {d} fail, {d} updated\n", .{ pass, fail, updated });
    if (fail > 0) std.process.exit(1);
}

fn die(msg: []const u8) noreturn {
    _ = std.c.write(2, msg.ptr, msg.len);
    _ = std.c.write(2, "\n", 1);
    std.process.exit(2);
}

// ─── scenario discovery ──────────────────────────────────────────────────

const Scenario = struct {
    name: []u8,
    dir: []u8,
    script_path: []u8,

    pub fn deinit(self: *Scenario, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.dir);
        allocator.free(self.script_path);
    }
};

fn discoverScenarios(io: std.Io, allocator: Allocator, root_path: []const u8, out: *std.ArrayList(Scenario)) !void {
    var cwd = std.Io.Dir.cwd();
    var root = cwd.openDir(io, root_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer root.close(io);

    var walker = root.iterate();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .directory) continue;

        const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root_path, entry.name });
        errdefer allocator.free(dir_path);

        const script_path = try std.fmt.allocPrint(allocator, "{s}/scenario.e2e", .{dir_path});
        errdefer allocator.free(script_path);

        cwd.access(io, script_path, .{}) catch {
            allocator.free(dir_path);
            allocator.free(script_path);
            continue;
        };

        try out.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .dir = dir_path,
            .script_path = script_path,
        });
    }

    // Stable order so output is deterministic.
    std.mem.sort(Scenario, out.items, {}, struct {
        fn less(_: void, a: Scenario, b: Scenario) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);
}

// ─── scenario execution ──────────────────────────────────────────────────

const Result = union(enum) {
    pass,
    updated,
    fail: []const u8,
};

/// Per-scenario binary selection. If `<scenario>/config.zig` exists,
/// build atty with that config into a scenario-private prefix and
/// return its path. Otherwise return the default binary.
///
/// Extra build flags (e.g. `-Dtarget=x86_64-linux-gnu` for hosts where
/// the native crt1 doesn't link) flow through `ATTY_E2E_BUILD_FLAGS`,
/// space-separated. Zig's own build cache handles "did the inputs
/// change" — repeated runs are no-ops when nothing changed.
fn buildScenarioBin(io: std.Io, gpa: Allocator, sc: Scenario, default_bin: []const u8) ![]const u8 {
    var cwd = std.Io.Dir.cwd();
    const cfg_path = try std.fmt.allocPrint(gpa, "{s}/config.zig", .{sc.dir});
    defer gpa.free(cfg_path);

    cwd.access(io, cfg_path, .{}) catch return try gpa.dupe(u8, default_bin);

    const prefix = try std.fmt.allocPrint(gpa, ".zig-cache/e2e/{s}", .{sc.name});
    defer gpa.free(prefix);

    const dconfig = try std.fmt.allocPrint(gpa, "-Dconfig={s}", .{cfg_path});
    defer gpa.free(dconfig);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "zig");
    try argv.append(gpa, "build");
    try argv.append(gpa, "install");
    try argv.append(gpa, "-Doptimize=ReleaseSafe");
    try argv.append(gpa, dconfig);
    try argv.append(gpa, "--prefix");
    try argv.append(gpa, prefix);

    if (getenv("ATTY_E2E_BUILD_FLAGS")) |raw| {
        var it = std.mem.tokenizeAny(u8, std.mem.sliceTo(raw, 0), " \t");
        while (it.next()) |tok| try argv.append(gpa, tok);
    }

    const result = std.process.run(gpa, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(1 << 16),
    }) catch return error.ScenarioBuildFailed;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("\n[e2e] {s}: scenario build failed (exit {d}):\n{s}\n", .{ sc.name, code, result.stderr });
            return error.ScenarioBuildFailed;
        },
        else => {
            std.debug.print("\n[e2e] {s}: scenario build terminated abnormally\n", .{sc.name});
            return error.ScenarioBuildFailed;
        },
    }

    return try std.fmt.allocPrint(gpa, "{s}/bin/atty", .{prefix});
}

fn runScenario(io: std.Io, gpa: Allocator, sc: Scenario, atty_bin: []const u8, update: bool) !Result {
    var cwd = std.Io.Dir.cwd();

    // Per-scenario config support: if <scenario>/config.zig exists, we
    // rebuild atty with that config into a scenario-private prefix.
    // The returned path is either the default bin (no per-scenario
    // config) or our freshly-built one.
    const scenario_bin = try buildScenarioBin(io, gpa, sc, atty_bin);
    defer gpa.free(scenario_bin);

    const source = try cwd.readFileAlloc(io, sc.script_path, gpa, .limited(1 << 20));
    defer gpa.free(source);

    var script = try dsl.parse(gpa, source);
    defer script.deinit();

    // ── Pass 1: collect config (cols/rows/env/spawn) without spawning yet.
    var cols: u16 = 80;
    var rows: u16 = 24;
    var timeout_ms: u32 = 5000;
    var extra_env: std.ArrayList(harness.KV) = .empty;
    defer extra_env.deinit(gpa);

    // Resolve the scenario directory to an absolute path and expose
    // it via `$ATTY_SCENARIO_DIR` so scenarios can reference
    // fixture files (e.g. `cat $ATTY_SCENARIO_DIR/../fixtures/foo`).
    // The harness's child gets `HOME=/tmp` and no useful default
    // cwd anchor; without this, no scenario could load fixtures.
    var path_buf: [4096]u8 = undefined;
    const scenario_dir_abs = if (sc.dir.len > 0 and sc.dir[0] == '/') blk: {
        // `sc.dir` already absolute — runner invoked with an
        // absolute tests path, e.g. `--root /abs/tests/e2e`.
        // Prefixing CWD would produce `<cwd>/<abs>/...` which
        // cat would fail to resolve.
        break :blk try gpa.dupe(u8, sc.dir);
    } else blk: {
        const cwd_rc = std.c.getcwd(@ptrCast(&path_buf), path_buf.len);
        const cwd_abs: ?[]const u8 = if (cwd_rc == null) null else std.mem.sliceTo(@as([*:0]const u8, @ptrCast(cwd_rc.?)), 0);
        break :blk if (cwd_abs) |c|
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ c, sc.dir })
        else
            try gpa.dupe(u8, sc.dir);
    };
    defer gpa.free(scenario_dir_abs);
    try extra_env.append(gpa, .{ .key = "ATTY_SCENARIO_DIR", .value = scenario_dir_abs });
    var spawn_argv: []const []const u8 = &.{};
    var spawn_seen = false;
    var first_cmd_after_spawn: usize = 0;

    for (script.cmds, 0..) |c, i| {
        switch (c.kind) {
            .set_cols => cols = @intCast(c.int_arg),
            .set_rows => rows = @intCast(c.int_arg),
            .set_timeout_ms => timeout_ms = @intCast(c.int_arg),
            .set_env => try extra_env.append(gpa, .{ .key = c.str_arg, .value = c.str_arg2 }),
            .spawn => {
                if (spawn_seen) return .{ .fail = "multiple spawn directives" };
                spawn_argv = c.argv;
                spawn_seen = true;
                first_cmd_after_spawn = i + 1;
            },
            else => {
                if (!spawn_seen) {} // ignore until spawn
            },
        }
    }
    if (!spawn_seen) return .{ .fail = "scenario has no spawn directive" };

    const forced_env = [_]harness.KV{
        .{ .key = "PATH", .value = "/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin" },
        .{ .key = "TERM", .value = "xterm-256color" },
        .{ .key = "LANG", .value = "C.UTF-8" },
        .{ .key = "LC_ALL", .value = "C.UTF-8" },
        .{ .key = "HOME", .value = "/tmp" },
        .{ .key = "SHELL", .value = "/bin/sh" },
        .{ .key = "USER", .value = "test" },
        .{ .key = "PS1", .value = "$ " },
    };

    var session = try harness.spawn(gpa, .{
        .atty_bin = scenario_bin,
        .argv = spawn_argv,
        .cols = cols,
        .rows = rows,
        .forced_env = &forced_env,
        .extra_env = extra_env.items,
    });
    defer session.deinit();

    // ── Pass 2: execute commands after spawn.
    var first_failure: ?[]const u8 = null;
    var any_update = false;

    // Give the child a moment to render its initial prompt.
    _ = try session.pumpMs(50);

    for (script.cmds[first_cmd_after_spawn..]) |c| {
        if (first_failure != null) break;
        switch (c.kind) {
            .set_cols, .set_rows, .set_timeout_ms, .set_env, .spawn => {
                // Config directives must come before spawn; ignore here.
            },
            .type_str => try session.writeInput(c.str_arg),
            .key => {
                const bytes = dsl.keyBytes(c.str_arg) orelse {
                    first_failure = "unknown key";
                    break;
                };
                try session.writeInput(bytes);
            },
            .sleep => try session.sleepMs(@intCast(c.int_arg)),
            .wait_for => {
                const found = try session.waitFor(c.str_arg, timeout_ms);
                if (!found) {
                    first_failure = "wait_for timeout";
                    break;
                }
            },
            .expect_substr => {
                if (!session.gridContains(c.str_arg)) {
                    first_failure = "expect_substr missing";
                    break;
                }
            },
            .expect_no_substr => {
                if (session.gridContains(c.str_arg)) {
                    first_failure = "expect_no_substr present";
                    break;
                }
            },
            .snapshot => {
                var frame = try session.captureFrame();
                defer frame.deinit();
                const golden_dir = try std.fmt.allocPrint(gpa, "{s}/golden/{s}", .{ sc.dir, c.str_arg });
                defer gpa.free(golden_dir);

                if (update) {
                    try snapshot.writeGoldenFrame(io, golden_dir, &frame);
                    any_update = true;
                } else {
                    const cmp = try snapshot.compareFrame(io, gpa, golden_dir, &frame);
                    switch (cmp) {
                        .match => {},
                        .missing_golden => {
                            const actual_dir = try std.fmt.allocPrint(gpa, "{s}/actual/{s}", .{ sc.dir, c.str_arg });
                            defer gpa.free(actual_dir);
                            try snapshot.writeActualFrame(io, actual_dir, &frame);
                            first_failure = "snapshot golden missing (run with --update to create)";
                        },
                        .mismatch => {
                            const actual_dir = try std.fmt.allocPrint(gpa, "{s}/actual/{s}", .{ sc.dir, c.str_arg });
                            defer gpa.free(actual_dir);
                            try snapshot.writeActualFrame(io, actual_dir, &frame);
                            first_failure = "snapshot mismatch (see actual/ next to golden/)";
                        },
                    }
                }
            },
            .exit => {
                // Send EOT; child cooperatively exits.
                try session.writeInput("\x04");
                _ = try session.waitExit(timeout_ms);
            },
            .exit_code => {
                if (!session.exited) _ = try session.waitExit(timeout_ms);
                const got: i64 = @intCast(if (linux_WIFEXITED(session.exit_status)) linux_WEXITSTATUS(session.exit_status) else 128);
                if (got != c.int_arg) first_failure = "exit_code mismatch";
            },
        }
    }

    // Always shut down cleanly.
    session.terminate();

    // On update or pass: write env.toml + cast.json into golden/.
    if (update or first_failure == null) {
        const golden_root = try std.fmt.allocPrint(gpa, "{s}/golden", .{sc.dir});
        defer gpa.free(golden_root);
        try cwd.createDirPath(io, golden_root);

        const env_path = try std.fmt.allocPrint(gpa, "{s}/env.toml", .{golden_root});
        defer gpa.free(env_path);
        const cast_path = try std.fmt.allocPrint(gpa, "{s}/cast.json", .{golden_root});
        defer gpa.free(cast_path);

        if (update) {
            // Write env.toml.
            var env_file = try cwd.createFile(io, env_path, .{});
            defer env_file.close(io);
            var env_buf: [4096]u8 = undefined;
            var env_w = env_file.writerStreaming(io, &env_buf);
            try snapshot.writeEnv(&env_w.interface, .{
                .atty_version = atty.version,
                .cols = cols,
                .rows = rows,
                .argv = spawn_argv,
                .forced_env = blk: {
                    var arr: [forced_env.len]snapshot.EnvSnapshot.KV = undefined;
                    for (&forced_env, 0..) |kv, i| arr[i] = .{ .key = kv.key, .value = kv.value };
                    break :blk arr[0..];
                },
                .extra_env = blk: {
                    // Filter out `ATTY_SCENARIO_DIR` from the
                    // committed env snapshot — its value is an
                    // absolute, machine-specific path (e.g. /home/
                    // alice/atty/tests/e2e/<scenario>) that would
                    // produce a different golden on every dev
                    // checkout. The runtime injection still happens
                    // unconditionally; we only redact it from
                    // disk.
                    var count: usize = 0;
                    for (extra_env.items) |kv| {
                        if (!std.mem.eql(u8, kv.key, "ATTY_SCENARIO_DIR")) count += 1;
                    }
                    var arr = try gpa.alloc(snapshot.EnvSnapshot.KV, count);
                    var w_idx: usize = 0;
                    for (extra_env.items) |kv| {
                        if (std.mem.eql(u8, kv.key, "ATTY_SCENARIO_DIR")) continue;
                        arr[w_idx] = .{ .key = kv.key, .value = kv.value };
                        w_idx += 1;
                    }
                    break :blk arr;
                },
            });
            try env_w.interface.flush();

            // Write cast.json.
            var cast_file = try cwd.createFile(io, cast_path, .{});
            defer cast_file.close(io);
            var cast_buf: [4096]u8 = undefined;
            var cast_w = cast_file.writerStreaming(io, &cast_buf);
            try session.cast.write(&cast_w.interface);
            try cast_w.interface.flush();
        }
    }

    if (first_failure) |w| return .{ .fail = w };
    if (any_update) return .updated;
    return .pass;
}

fn linux_WIFEXITED(status: u32) bool {
    return (status & 0x7F) == 0;
}
fn linux_WEXITSTATUS(status: u32) u8 {
    return @intCast((status >> 8) & 0xFF);
}
