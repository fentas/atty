const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -------------------------------------------------------------------------
    // -Dconfig=path/to/config.zig
    //
    // Defaults to src/config.zig. Pass an absolute path to use a config
    // tracked outside the repo. The user's file accesses modules via
    // `@import("atty").modules.*`.
    // -------------------------------------------------------------------------
    const config_path = b.option(
        []const u8,
        "config",
        "Path to config.zig (default: src/config.zig)",
    ) orelse "src/config.zig";

    // Bootstrap the user config on first build. src/config.zig is
    // gitignored (per-user); src/config.def.zig is the committed
    // template. On a fresh clone we copy the template across so the
    // build doesn't fail and the user has a starting point with
    // commented examples. Idempotent — only copies if the destination
    // is missing.
    if (std.mem.eql(u8, config_path, "src/config.zig")) {
        seedConfig(b, "src/config.def.zig", "src/config.zig");
    }
    // attop's panel config — same dwm-style def/user split. Idempotent, so
    // it's safe to seed unconditionally (only the `attop` steps read it).
    seedConfig(b, "src/attop/config.def.zig", "src/attop/config.zig");
    // The ttysnap module config — same dwm-style def/user split.
    seedConfig(b, "src/ttysnap/config.def.zig", "src/ttysnap/config.zig");

    // atty library module — owns every source file under src/ except
    // config.zig. Keeping them in a single named module avoids
    // "file in multiple modules" collisions.
    const atty_module = b.addModule("atty", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // User-editable config — possibly empty. Only declarations the user
    // makes here win; everything else falls through to defaults.zig.
    const user_config_module = b.createModule(.{
        .root_source_file = b.path(config_path),
        .target = target,
        .optimize = optimize,
    });
    user_config_module.addImport("atty", atty_module);

    // The resolver merges user_config with defaults.zig. This is what
    // every internal consumer sees when it does `@import("config")`.
    // New tunables added to defaults.zig + the resolver flow through
    // to existing user configs with zero changes on their side.
    const config_module = b.createModule(.{
        .root_source_file = b.path("src/config_resolver.zig"),
        .target = target,
        .optimize = optimize,
    });
    config_module.addImport("user_config", user_config_module);
    config_module.addImport("atty", atty_module);

    // Two-way cycle (proxy reads config.modules; defaults reads
    // atty.modules.*). Zig resolves it lazily — each side only needs
    // the types the other exposes.
    atty_module.addImport("config", config_module);

    // -------------------------------------------------------------------------
    // Executable
    // -------------------------------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "atty",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "atty", .module = atty_module },
                .{ .name = "config", .module = config_module },
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // -------------------------------------------------------------------------
    // Unit tests
    // -------------------------------------------------------------------------
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unit_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // -------------------------------------------------------------------------
    // attop — the dashboard TUI (docs/dashboard.md). A standalone binary
    // (the "Grafana" of atty) that reads the atty-guard metrics API; reuses
    // the atty module's style/ansi primitives. NOT in the default install
    // (the proxy stays the lean default per the Suckless ethos); `zig build
    // attop` installs it (release ships it; `tui.atty.sh` fetches it) and
    // `zig build run-attop` runs it in place for dev.
    // -------------------------------------------------------------------------
    // The VT-grid emulator (also used by the proxy e2e harness) — exposed
    // as a module so attop's screenshot tests can feed a rendered frame
    // through it and assert the on-screen grid. (@import can't reach across
    // module subtrees, hence a named import.)
    const vt_module = b.createModule(.{
        .root_source_file = b.path("src/test/e2e/vt.zig"),
        .target = target,
        .optimize = optimize,
    });
    // The low-level PTY spawn (openpt/grantpt/fork/execvpe + childSetup), shared
    // by ttysnap and the e2e harness so there's ONE controlled-env spawner. Its
    // home stays under src/ttysnap/ (ttysnap remains self-contained for spinout).
    const pty_module = b.createModule(.{
        .root_source_file = b.path("src/ttysnap/pty.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // own externs + std.c.*
    });
    // Generic poll-until + grid-query helpers, shared by the same two drivers so
    // the wait loops live once. Generic over the driver (anytype), depends on
    // nothing but std (+ libc for the monotonic clock).
    const wait_module = b.createModule(.{
        .root_source_file = b.path("src/ttysnap/wait.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // std.c.clock_gettime
    });
    // Char-by-char typing with selectable cadence — the input-side sibling of
    // `wait`, shared by the same drivers. Pulls `wait` for the inter-key sleep.
    const typing_module = b.createModule(.{
        .root_source_file = b.path("src/ttysnap/typing.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "wait", .module = wait_module }},
    });
    // unit_tests pulls test/e2e/dsl.zig relatively, which now imports `typing`;
    // make the module resolvable in that graph too (it carries its own `wait`).
    unit_tests.root_module.addImport("typing", typing_module);

    const attop_module = b.createModule(.{
        .root_source_file = b.path("src/attop/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "atty", .module = atty_module },
            .{ .name = "vt", .module = vt_module },
        },
    });
    const attop_exe = b.addExecutable(.{ .name = "attop", .root_module = attop_module });

    // `zig build attop` installs the binary to zig-out/bin/attop (release +
    // the tui.atty.sh installer build this), kept off the default install.
    const attop_step = b.step("attop", "Build + install the attop dashboard binary");
    attop_step.dependOn(&b.addInstallArtifact(attop_exe, .{}).step);

    const run_attop = b.addRunArtifact(attop_exe);
    if (b.args) |args| run_attop.addArgs(args);
    const run_attop_step = b.step("run-attop", "Run the attop dashboard");
    run_attop_step.dependOn(&run_attop.step);

    // attop's unit tests fold into `zig build test`.
    const attop_tests = b.addTest(.{ .root_module = attop_module });
    test_step.dependOn(&b.addRunArtifact(attop_tests).step);

    // -------------------------------------------------------------------------
    // ttysnap — the composable "Playwright for TTY" test framework
    // (docs/ttysnap.md). A standalone binary built from its own `config.zig`
    // module tuple, reusing the `vt` grid. `zig build ttysnap` builds it,
    // `zig build run-ttysnap` runs the configured example.
    // -------------------------------------------------------------------------
    const ttysnap_module = b.createModule(.{
        .root_source_file = b.path("src/ttysnap/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // io.zig uses std.c.*
        .imports = &.{
            .{ .name = "vt", .module = vt_module },
            .{ .name = "pty", .module = pty_module },
            .{ .name = "wait", .module = wait_module },
            .{ .name = "typing", .module = typing_module },
        },
    });
    const ttysnap_exe = b.addExecutable(.{ .name = "ttysnap", .root_module = ttysnap_module });
    const ttysnap_step = b.step("ttysnap", "Build the ttysnap test-harness binary");
    ttysnap_step.dependOn(&b.addInstallArtifact(ttysnap_exe, .{}).step);

    const run_ttysnap = b.addRunArtifact(ttysnap_exe);
    if (b.args) |args| run_ttysnap.addArgs(args);
    const run_ttysnap_step = b.step("run-ttysnap", "Run the ttysnap example");
    run_ttysnap_step.dependOn(&run_ttysnap.step);

    // ttysnap unit tests: fold into `zig build test`, plus a focused
    // `zig build test-ttysnap` for fast iteration.
    const ttysnap_tests = b.addTest(.{ .root_module = ttysnap_module });
    const run_ttysnap_tests = b.addRunArtifact(ttysnap_tests);
    test_step.dependOn(&run_ttysnap_tests.step);
    const ttysnap_test_step = b.step("test-ttysnap", "Run only the ttysnap unit tests");
    ttysnap_test_step.dependOn(&run_ttysnap_tests.step);

    // The shared wait/grid helpers test against a fake driver (no PTY).
    const wait_tests = b.addTest(.{ .root_module = wait_module });
    test_step.dependOn(&b.addRunArtifact(wait_tests).step);
    // The typing helper tests against a fake driver too.
    const typing_tests = b.addTest(.{ .root_module = typing_module });
    test_step.dependOn(&b.addRunArtifact(typing_tests).step);

    // -------------------------------------------------------------------------
    // Integration tests
    // -------------------------------------------------------------------------
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test/integration.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "atty", .module = atty_module },
            },
        }),
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);

    const itest_step = b.step("itest", "Run integration tests (requires PTY)");
    itest_step.dependOn(&run_integration_tests.step);

    // -------------------------------------------------------------------------
    // Live-Ollama tests
    //
    // Hits a REAL `OLLAMA_HOST` / `LLM_API_BASE` endpoint instead of mocking
    // HTTP. Each test starts with a reachability probe and skips (rather
    // than fails) when the endpoint isn't responding — so CI without
    // Ollama just sees "X skipped".
    //
    //     OLLAMA_HOST=http://localhost:11434 zig build ollama
    //     ATTY_TEST_MODEL=qwen2.5:3b zig build ollama
    // -------------------------------------------------------------------------
    const ollama_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test/ollama_live.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "atty", .module = atty_module },
            },
        }),
    });
    const run_ollama_tests = b.addRunArtifact(ollama_tests);
    // Skip the build-cache hit when the user supplies env vars — Zig
    // caches based on inputs, and the env is part of runtime, so a
    // stale cached binary would silently reuse an old probe result.
    // `has_side_effects` tells the build graph "don't dedupe me."
    run_ollama_tests.has_side_effects = true;
    const ollama_step = b.step("ollama", "Run live-Ollama tests (skip when OLLAMA_HOST unreachable)");
    ollama_step.dependOn(&run_ollama_tests.step);

    // -------------------------------------------------------------------------
    // E2E framework
    //
    // Builds a standalone runner that spawns `atty` under a controlled PTY,
    // drives input from .e2e scripts, captures output through an in-tree VT
    // emulator, and diffs against goldens.
    //
    //     zig build e2e                # compare to goldens
    //     zig build e2e -- --update    # write/refresh goldens
    //     zig build e2e -- --filter X  # run scenarios whose name contains X
    // -------------------------------------------------------------------------
    const e2e_runner = b.addExecutable(.{
        .name = "atty-e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test/e2e/runner.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "atty", .module = atty_module },
                .{ .name = "pty", .module = pty_module },
                .{ .name = "wait", .module = wait_module },
                .{ .name = "typing", .module = typing_module },
            },
        }),
    });

    const run_e2e = b.addRunArtifact(e2e_runner);
    run_e2e.step.dependOn(&exe.step); // ensure atty is built first
    run_e2e.addArg("--bin");
    run_e2e.addFileArg(exe.getEmittedBin());
    run_e2e.addArg("tests/e2e");
    if (b.args) |a| run_e2e.addArgs(a);
    // We want to see scenario output even when the runner exits cleanly.
    run_e2e.has_side_effects = true;

    const e2e_step = b.step("e2e", "Run end-to-end scenarios (requires PTY)");
    e2e_step.dependOn(&run_e2e.step);

    // The same runner over tests/demo — the per-feature showcase scenarios that
    // back the docs GIFs (kept OUT of the regression suite: they're paced with
    // sleeps + typed at human cadence). `zig build demo -- --update` records the
    // casts; scripts/gen-demo-gifs.sh then runs `agg` over them.
    const run_demo = b.addRunArtifact(e2e_runner);
    run_demo.step.dependOn(&exe.step);
    run_demo.addArg("--bin");
    run_demo.addFileArg(exe.getEmittedBin());
    run_demo.addArg("tests/demo");
    if (b.args) |a| run_demo.addArgs(a);
    run_demo.has_side_effects = true;
    const demo_step = b.step("demo", "Record the demo-GIF casts (tests/demo)");
    demo_step.dependOn(&run_demo.step);

    // -------------------------------------------------------------------------
    // Benchmarks (Tier A — in-process microbenchmarks)
    //
    // Times the per-keystroke hot path + reports allocs/op (zero-alloc
    // claim). Build in a Release mode — Debug numbers are noise.
    //
    //     zig build bench -Doptimize=ReleaseFast
    //     zig build bench -Doptimize=ReleaseFast -- --json
    //     zig build bench -Doptimize=ReleaseFast -- --filter dispatch
    // -------------------------------------------------------------------------
    const bench_module = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "atty", .module = atty_module },
        },
    });
    const bench_exe = b.addExecutable(.{ .name = "atty-bench", .root_module = bench_module });
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.has_side_effects = true; // always re-run; never cache the numbers
    if (b.args) |a| run_bench.addArgs(a);
    const bench_step = b.step("bench", "Run microbenchmarks (REQUIRES -Doptimize=ReleaseFast for meaningful numbers)");
    bench_step.dependOn(&run_bench.step);

    // The harness's zero-allocation-hot-path assertion runs under
    // `zig build test` so a regression in that claim fails CI — the
    // bench binary itself is opt-in, but its guarantee is not.
    const bench_tests = b.addTest(.{ .root_module = bench_module });
    const run_bench_tests = b.addRunArtifact(bench_tests);
    test_step.dependOn(&run_bench_tests.step);
}

/// Copy `def_path` → `user_path` if the latter is missing. Safe to call on
/// every build — short-circuits when the destination exists. Used for both
/// the proxy's config (src/config.zig) and attop's panel config
/// (src/attop/config.zig): the committed `*.def.zig` is the template, the
/// user's copy is gitignored so `git pull` won't fight local edits.
fn seedConfig(b: *std.Build, def_path: []const u8, user_path: []const u8) void {
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    cwd.access(io, user_path, .{}) catch {
        // Open template, create destination, stream bytes.
        var src = cwd.openFile(io, def_path, .{}) catch |e| {
            std.debug.print("note: could not open {s}: {t}\n", .{ def_path, e });
            return;
        };
        defer src.close(io);

        var dst = cwd.createFile(io, user_path, .{}) catch |e| {
            std.debug.print("note: could not create {s}: {t}\n", .{ user_path, e });
            return;
        };
        defer dst.close(io);

        var buf: [4096]u8 = undefined;
        var src_reader_buf: [4096]u8 = undefined;
        var src_reader = src.reader(io, &src_reader_buf);
        var dst_writer_buf: [4096]u8 = undefined;
        var dst_writer = dst.writerStreaming(io, &dst_writer_buf);
        while (true) {
            const n = src_reader.interface.readSliceShort(&buf) catch break;
            if (n == 0) break;
            dst_writer.interface.writeAll(buf[0..n]) catch break;
        }
        dst_writer.interface.flush() catch {};
    };
}
