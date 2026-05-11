//! atty — entry point.
//!
//! Usage: atty [flags] [-- shell args...]
//!
//! Flags:
//!   --shell <path>   Shell binary to spawn (default: $SHELL or /bin/sh)
//!   -h, --help       Print this help
//!
//! Anything after `--` is passed verbatim to the child shell as argv.
//!
//! Module composition is *not* a runtime concern — edit `src/config.zig`
//! and recompile. See README.md for the rationale.

const std = @import("std");
const posix = std.posix;
const atty = @import("atty");

const usage =
    \\Usage: atty [flags] [-- shell args...]
    \\
    \\Flags:
    \\  --shell <path>   Shell binary to spawn (default: $SHELL or /bin/sh)
    \\  -h, --help       Print this help
    \\
    \\Module composition is configured at build time via src/config.zig.
    \\Use `-Dconfig=path` to point zig build at a different config file.
    \\
;

const CliOpts = struct {
    shell_override: ?[]const u8 = null,
    shell_args: [][]const u8 = &.{},
};

fn parseArgs(allocator: std.mem.Allocator) !CliOpts {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var opts = CliOpts{};
    var i: usize = 1;
    var saw_separator = false;

    var passthrough = std.ArrayList([]const u8).init(allocator);
    errdefer passthrough.deinit();

    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (saw_separator) {
            try passthrough.append(try allocator.dupe(u8, a));
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            saw_separator = true;
            continue;
        }
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try std.io.getStdOut().writeAll(usage);
            std.process.exit(0);
        }
        if (std.mem.eql(u8, a, "--shell")) {
            i += 1;
            if (i >= args.len) {
                try std.io.getStdErr().writeAll("error: --shell requires a value\n");
                std.process.exit(2);
            }
            opts.shell_override = try allocator.dupe(u8, args[i]);
            continue;
        }
        try std.io.getStdErr().writer().print("error: unknown flag: {s}\n\n", .{a});
        try std.io.getStdErr().writeAll(usage);
        std.process.exit(2);
    }

    opts.shell_args = try passthrough.toOwnedSlice();
    return opts;
}

fn resolveShell(allocator: std.mem.Allocator, override: ?[]const u8) ![:0]u8 {
    if (override) |s| return try allocator.dupeZ(u8, s);
    if (std.posix.getenv("SHELL")) |s| return try allocator.dupeZ(u8, s);
    return try allocator.dupeZ(u8, "/bin/sh");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const opts = try parseArgs(allocator);
    defer {
        if (opts.shell_override) |s| allocator.free(s);
        for (opts.shell_args) |s| allocator.free(s);
        allocator.free(opts.shell_args);
    }

    const shell_path = try resolveShell(allocator, opts.shell_override);
    defer allocator.free(shell_path);

    // Build argv = [shell_path, opts.shell_args..., null]
    var argv_list = std.ArrayList(?[*:0]const u8).init(allocator);
    defer {
        for (argv_list.items) |maybe_arg| {
            if (maybe_arg) |arg| {
                const slice = std.mem.sliceTo(arg, 0);
                allocator.free(slice.ptr[0 .. slice.len + 1]);
            }
        }
        argv_list.deinit();
    }
    try argv_list.append(try allocator.dupeZ(u8, shell_path));
    for (opts.shell_args) |a| try argv_list.append(try allocator.dupeZ(u8, a));
    try argv_list.append(null);
    const argv: [*:null]const ?[*:0]const u8 = @ptrCast(argv_list.items.ptr);

    const is_tty = std.io.getStdOut().isTty() and std.io.getStdIn().isTty();

    const info = try atty.proxy.run(allocator, .{
        .argv = argv,
        .is_tty = is_tty,
    });

    std.process.exit(info.exit_code);
}
