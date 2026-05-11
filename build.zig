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

    // The `atty` library module owns every source file under src/ that
    // isn't config.zig — including the built-in modules. Keeping
    // everything in a single named module avoids "file in multiple
    // modules" errors when both the proxy and a user config reach the
    // same internal helper.
    const atty_module = b.addModule("atty", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The user's config lives in its own named module so the proxy can
    // `@import("config")` without dragging the whole tree through a
    // user-edited file.
    const config_module = b.createModule(.{
        .root_source_file = b.path(config_path),
        .target = target,
        .optimize = optimize,
    });
    config_module.addImport("atty", atty_module);

    // atty's proxy reads `config.modules` at comptime — wire the
    // dependency the other way too. Zig resolves the cycle lazily:
    // each side only needs the *types* exposed by the other.
    atty_module.addImport("config", config_module);

    // -------------------------------------------------------------------------
    // Executable
    // -------------------------------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "atty",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    exe.root_module.addImport("atty", atty_module);
    exe.root_module.addImport("config", config_module);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // -------------------------------------------------------------------------
    // Unit tests — use a separate root so the test exe doesn't share a
    // source file with the `atty` library module.
    // -------------------------------------------------------------------------
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/unit_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.linkLibC();

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // -------------------------------------------------------------------------
    // Integration tests — exercise the real PTY plumbing.
    // -------------------------------------------------------------------------
    const integration_tests = b.addTest(.{
        .root_source_file = b.path("src/test/integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_tests.linkLibC();
    integration_tests.root_module.addImport("atty", atty_module);

    const run_integration_tests = b.addRunArtifact(integration_tests);

    const itest_step = b.step("itest", "Run integration tests (requires PTY)");
    itest_step.dependOn(&run_integration_tests.step);
}
