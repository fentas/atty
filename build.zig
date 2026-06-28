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
        bootstrapUserConfig(b);
    }

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
    // the atty module's style/ansi primitives. Opt-in to build/install.
    // -------------------------------------------------------------------------
    const attop_module = b.createModule(.{
        .root_source_file = b.path("src/attop/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "atty", .module = atty_module },
        },
    });
    const attop_exe = b.addExecutable(.{ .name = "attop", .root_module = attop_module });
    b.installArtifact(attop_exe);

    const run_attop = b.addRunArtifact(attop_exe);
    run_attop.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_attop.addArgs(args);
    const run_attop_step = b.step("run-attop", "Run the attop dashboard");
    run_attop_step.dependOn(&run_attop.step);

    // attop's unit tests fold into `zig build test`.
    const attop_tests = b.addTest(.{ .root_module = attop_module });
    test_step.dependOn(&b.addRunArtifact(attop_tests).step);

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

/// Copy `src/config.def.zig` → `src/config.zig` if the latter is missing.
/// Safe to call on every build — short-circuits when the file exists.
fn bootstrapUserConfig(b: *std.Build) void {
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    cwd.access(io, "src/config.zig", .{}) catch {
        // Open template, create destination, stream bytes.
        var src = cwd.openFile(io, "src/config.def.zig", .{}) catch |e| {
            std.debug.print("note: could not open src/config.def.zig: {t}\n", .{e});
            return;
        };
        defer src.close(io);

        var dst = cwd.createFile(io, "src/config.zig", .{}) catch |e| {
            std.debug.print("note: could not create src/config.zig: {t}\n", .{e});
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
