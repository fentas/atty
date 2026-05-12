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

    // atty library module — owns every source file under src/ except
    // config.zig. Keeping them in a single named module avoids
    // "file in multiple modules" collisions.
    const atty_module = b.addModule("atty", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // User-editable config module.
    const config_module = b.createModule(.{
        .root_source_file = b.path(config_path),
        .target = target,
        .optimize = optimize,
    });

    // Two-way cycle: proxy reads `config.modules`; config reads
    // `atty.modules.*`. Zig resolves the cycle lazily because each side
    // only needs the *types* exposed by the other.
    config_module.addImport("atty", atty_module);
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
}
