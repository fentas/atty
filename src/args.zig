//! atty's CLI argument parser.
//!
//! `parseArgv` is the pure positional-collector — it takes an
//! already-iterated argv tail (so the caller has stripped argv[0])
//! and returns an outcome the caller can pattern-match on. Errors
//! that need a process exit (help, version, unknown flag) come back
//! as variants instead of side-effecting writes + std.process.exit
//! from inside the parser; that keeps this file testable without
//! launching subprocesses or swallowing process state.
//!
//! main.zig wraps this with the actual std.process.ArgsIterator and
//! handles the variants (printing usage, calling std.process.exit).

const std = @import("std");

pub const CliOpts = struct {
    /// argv for the spawned shell. positional[0] is the shell binary;
    /// positional[1..] are its args. Empty when the user passed no
    /// positionals — main.zig falls back to $SHELL in that case.
    positional: [][]const u8 = &.{},
};

/// Possible outcomes from `parseArgv`. main.zig matches on this and
/// decides what to print + which exit code to use.
pub const ParseOutcome = union(enum) {
    ok: CliOpts,
    help,
    version,
    unknown_flag: []const u8,
};

pub fn parseArgv(allocator: std.mem.Allocator, args: []const []const u8) !ParseOutcome {
    var positional: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (positional.items) |s| allocator.free(s);
        positional.deinit(allocator);
    }

    var done_with_flags = false;

    for (args) |a| {
        if (done_with_flags) {
            // Once we've started collecting the spawned command, every
            // subsequent token is part of it — flags included
            // (`atty bash -l` must pass `-l` to bash, not to atty).
            try positional.append(allocator, try allocator.dupe(u8, a));
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            done_with_flags = true;
            continue;
        }
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            return .help;
        }
        if (std.mem.eql(u8, a, "-V") or std.mem.eql(u8, a, "--version")) {
            return .version;
        }
        if (a.len > 0 and a[0] == '-') {
            return .{ .unknown_flag = a };
        }
        // First positional ends flag parsing.
        try positional.append(allocator, try allocator.dupe(u8, a));
        done_with_flags = true;
    }

    return .{ .ok = .{ .positional = try positional.toOwnedSlice(allocator) } };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn freeOk(allocator: std.mem.Allocator, opts: CliOpts) void {
    for (opts.positional) |s| allocator.free(s);
    allocator.free(opts.positional);
}

test "parseArgv collects no positionals when given an empty argv tail" {
    const got = try parseArgv(testing.allocator, &.{});
    try testing.expectEqual(@as(usize, 0), got.ok.positional.len);
    freeOk(testing.allocator, got.ok);
}

test "parseArgv treats the first non-flag as positional[0] and everything after as args" {
    const argv = [_][]const u8{ "bash", "-l", "-c", "echo hi" };
    const got = try parseArgv(testing.allocator, &argv);
    try testing.expectEqual(@as(usize, 4), got.ok.positional.len);
    try testing.expectEqualStrings("bash", got.ok.positional[0]);
    try testing.expectEqualStrings("-l", got.ok.positional[1]);
    try testing.expectEqualStrings("-c", got.ok.positional[2]);
    try testing.expectEqualStrings("echo hi", got.ok.positional[3]);
    freeOk(testing.allocator, got.ok);
}

test "parseArgv -- ends flag parsing without keeping the token itself" {
    const argv = [_][]const u8{ "--", "--weird-shell" };
    const got = try parseArgv(testing.allocator, &argv);
    try testing.expectEqual(@as(usize, 1), got.ok.positional.len);
    try testing.expectEqualStrings("--weird-shell", got.ok.positional[0]);
    freeOk(testing.allocator, got.ok);
}

test "parseArgv surfaces -h / --help" {
    var got = try parseArgv(testing.allocator, &.{"-h"});
    try testing.expect(got == .help);
    got = try parseArgv(testing.allocator, &.{"--help"});
    try testing.expect(got == .help);
}

test "parseArgv surfaces -V / --version" {
    var got = try parseArgv(testing.allocator, &.{"-V"});
    try testing.expect(got == .version);
    got = try parseArgv(testing.allocator, &.{"--version"});
    try testing.expect(got == .version);
}

test "parseArgv surfaces unknown flags before parsing positionals" {
    const got = try parseArgv(testing.allocator, &.{ "-x", "bash" });
    switch (got) {
        .unknown_flag => |f| try testing.expectEqualStrings("-x", f),
        else => return error.TestFailed,
    }
}

test "parseArgv: a known atty flag in the spawned-command tail is preserved, not consumed" {
    // The user can write `atty bash -l`, where `-l` is bash's flag,
    // not atty's. After the first positional, every later token is
    // verbatim — including ones that LOOK like atty flags.
    const argv = [_][]const u8{ "bash", "-h" };
    const got = try parseArgv(testing.allocator, &argv);
    try testing.expectEqual(@as(usize, 2), got.ok.positional.len);
    try testing.expectEqualStrings("bash", got.ok.positional[0]);
    try testing.expectEqualStrings("-h", got.ok.positional[1]);
    freeOk(testing.allocator, got.ok);
}
