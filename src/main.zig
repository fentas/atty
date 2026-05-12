//! atty — entry point.
//!
//! Usage: atty [flags] [shell [args...]]
//!
//!   atty                       # spawn $SHELL (or /bin/sh)
//!   atty bash                  # spawn bash
//!   atty bash -l               # spawn bash with -l
//!   atty zsh -c 'echo hi'      # spawn zsh -c 'echo hi'
//!   atty -- --weird-shell-name # `--` forces positional mode if needed
//!
//! Flags:
//!   -h, --help    Print this help
//!
//! Module composition is *not* a runtime concern — edit `src/config.zig`
//! and recompile. See README.md for the rationale.

const std = @import("std");
const atty = @import("atty");
const args_mod = atty.args;

const usage =
    \\Usage: atty [flags] [shell [args...]]
    \\
    \\  atty                  spawn $SHELL (default /bin/sh)
    \\  atty bash             spawn bash
    \\  atty bash -l          spawn bash with -l
    \\  atty zsh -c 'cmd'     spawn zsh -c 'cmd'
    \\
    \\Flags:
    \\  -h, --help            Print this help
    \\  -V, --version         Print version and exit
    \\
    \\Module composition is configured at build time via src/config.zig.
    \\Use `-Dconfig=path` to point zig build at a different config file.
    \\
;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
extern "c" fn isatty(fd: c_int) c_int;

const CliOpts = args_mod.CliOpts;

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

    var collected: std.ArrayList([]const u8) = .empty;
    defer {
        for (collected.items) |s| allocator.free(s);
        collected.deinit(allocator);
    }
    while (it.next()) |a| try collected.append(allocator, try allocator.dupe(u8, a));

    switch (try args_mod.parseArgv(allocator, collected.items)) {
        .ok => |opts| return opts,
        .help => {
            writeStdout(usage);
            std.process.exit(0);
        },
        .version => {
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "atty {s}\n", .{atty.version}) catch "atty\n";
            writeStdout(msg);
            std.process.exit(0);
        },
        .unknown_flag => |flag| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "error: unknown flag: {s}\n\n", .{flag}) catch "error: unknown flag\n";
            writeStderr(msg);
            writeStderr(usage);
            std.process.exit(2);
        },
    }
}

fn resolveShell(allocator: std.mem.Allocator) ![:0]u8 {
    if (getenv("SHELL")) |s| return try allocator.dupeZ(u8, std.mem.sliceTo(s, 0));
    return try allocator.dupeZ(u8, "/bin/sh");
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const opts = try parseArgs(allocator, init.minimal.args);
    defer {
        for (opts.positional) |s| allocator.free(s);
        allocator.free(opts.positional);
    }

    // Resolve the shell + extra args. If user passed positional args,
    // positional[0] is the shell binary; otherwise fall back to $SHELL.
    var shell_owned: ?[:0]u8 = null;
    defer if (shell_owned) |s| allocator.free(s);

    const shell_path: []const u8 = if (opts.positional.len > 0)
        opts.positional[0]
    else blk: {
        const s = try resolveShell(allocator);
        shell_owned = s;
        break :blk s;
    };
    const extra_args: []const []const u8 = if (opts.positional.len > 0)
        opts.positional[1..]
    else
        &.{};

    // Build argv = [shell_path, extra_args..., null]
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
    for (extra_args) |a| try argv_list.append(allocator, try allocator.dupeZ(u8, a));
    try argv_list.append(allocator, null);
    const argv: [*:null]const ?[*:0]const u8 = @ptrCast(argv_list.items.ptr);

    const is_tty = isatty(std.posix.STDOUT_FILENO) != 0 and isatty(std.posix.STDIN_FILENO) != 0;

    const info = try atty.proxy.run(allocator, io, .{
        .argv = argv,
        .is_tty = is_tty,
    });

    std.process.exit(info.exit_code);
}
