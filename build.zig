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
}
