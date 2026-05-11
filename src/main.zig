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

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
extern "c" fn isatty(fd: c_int) c_int;

const CliOpts = struct {
    shell_override: ?[]const u8 = null,
    shell_args: [][]const u8 = &.{},
};

fn writeStderr(bytes: []const u8) void {
    _ = std.c.write(std.posix.STDERR_FILENO, bytes.ptr, bytes.len);
}
fn writeStdout(bytes: []const u8) void {
    _ = std.c.write(std.posix.STDOUT_FILENO, bytes.ptr, bytes.len);
}

fn parseArgs(allocator: std.mem.Allocator, args: std.process.Args) !CliOpts {
    var it = try args.iterateAllocator(allocator);
    defer it.deinit();

    _ = it.next(); // argv[0]

    var opts = CliOpts{};
    var saw_separator = false;

    var passthrough: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (passthrough.items) |s| allocator.free(s);
        passthrough.deinit(allocator);
    }

    while (it.next()) |a| {
        if (saw_separator) {
            try passthrough.append(allocator, try allocator.dupe(u8, a));
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            saw_separator = true;
            continue;
        }
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            writeStdout(usage);
            std.process.exit(0);
        }
        if (std.mem.eql(u8, a, "--shell")) {
            const next = it.next() orelse {
                writeStderr("error: --shell requires a value\n");
                std.process.exit(2);
            };
            opts.shell_override = try allocator.dupe(u8, next);
            continue;
        }
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: unknown flag: {s}\n\n", .{a}) catch "error: unknown flag\n";
        writeStderr(msg);
        writeStderr(usage);
        std.process.exit(2);
    }

    opts.shell_args = try passthrough.toOwnedSlice(allocator);
    return opts;
}

fn resolveShell(allocator: std.mem.Allocator, override: ?[]const u8) ![:0]u8 {
    if (override) |s| return try allocator.dupeZ(u8, s);
    if (getenv("SHELL")) |s| return try allocator.dupeZ(u8, std.mem.sliceTo(s, 0));
    return try allocator.dupeZ(u8, "/bin/sh");
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const opts = try parseArgs(allocator, init.minimal.args);
    defer {
        if (opts.shell_override) |s| allocator.free(s);
        for (opts.shell_args) |s| allocator.free(s);
        allocator.free(opts.shell_args);
    }

    const shell_path = try resolveShell(allocator, opts.shell_override);
    defer allocator.free(shell_path);

    // Build argv = [shell_path, opts.shell_args..., null]
    var argv_list: std.ArrayList(?[*:0]const u8) = .empty;
    defer {
        for (argv_list.items) |maybe_arg| {
            if (maybe_arg) |arg| {
                const slice = std.mem.sliceTo(arg, 0);
                allocator.free(slice.ptr[0 .. slice.len + 1]);
            }
        }
        argv_list.deinit(allocator);
    }
    try argv_list.append(allocator, try allocator.dupeZ(u8, shell_path));
    for (opts.shell_args) |a| try argv_list.append(allocator, try allocator.dupeZ(u8, a));
    try argv_list.append(allocator, null);
    const argv: [*:null]const ?[*:0]const u8 = @ptrCast(argv_list.items.ptr);

    const is_tty = isatty(std.posix.STDOUT_FILENO) != 0 and isatty(std.posix.STDIN_FILENO) != 0;

    const info = try atty.proxy.run(allocator, io, .{
        .argv = argv,
        .is_tty = is_tty,
    });

    std.process.exit(info.exit_code);
}
