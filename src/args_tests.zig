//! Tests for `args.zig`. Lifted into a sibling so the
//! source file stays a manageable size.

const std = @import("std");
const testing = std.testing;
const mod = @import("args.zig");

// Re-binds of pub decls so test bodies stay short.
const CliOpts = mod.CliOpts;
const freePrintInit = mod.freePrintInit;
const isSafeShellName = mod.isSafeShellName;
const parseArgv = mod.parseArgv;
const ParseOutcome = mod.ParseOutcome;

// ===========================================================================
// Tests
// ===========================================================================

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

test "parseArgv: `init` is a subcommand that prints integration snippet" {
    // `atty init` yields .print_init with empty shell. `atty init
    // bash` carries the shell name through so the snippet's
    // `exec atty <shell>` matches the rc that's eval'ing it. The
    // payload is allocator-owned (duped) so tests must call
    // `freePrintInit` to keep the leak detector happy.
    const got1 = try parseArgv(testing.allocator, &.{"init"});
    defer freePrintInit(testing.allocator, got1.print_init);
    try testing.expect(got1 == .print_init);
    try testing.expectEqualStrings("", got1.print_init);

    const got2 = try parseArgv(testing.allocator, &.{ "init", "bash" });
    defer freePrintInit(testing.allocator, got2.print_init);
    try testing.expect(got2 == .print_init);
    try testing.expectEqualStrings("bash", got2.print_init);

    const got3 = try parseArgv(testing.allocator, &.{ "init", "zsh" });
    defer freePrintInit(testing.allocator, got3.print_init);
    try testing.expect(got3 == .print_init);
    try testing.expectEqualStrings("zsh", got3.print_init);
}

test "parseArgv: `doctor` is a subcommand that prints health-check snippet" {
    const got = try parseArgv(testing.allocator, &.{"doctor"});
    try testing.expect(got == .print_doctor);
}

test "parseArgv: `--` escape lets a user reach a real shell named `init`" {
    // Edge case — if someone genuinely has a shell binary called
    // `init`, `atty -- init` must spawn it instead of printing
    // the snippet.
    const got = try parseArgv(testing.allocator, &.{ "--", "init" });
    try testing.expectEqual(@as(usize, 1), got.ok.positional.len);
    try testing.expectEqualStrings("init", got.ok.positional[0]);
    freeOk(testing.allocator, got.ok);
}

test "isSafeShellName accepts the well-known shells" {
    try testing.expect(isSafeShellName("bash"));
    try testing.expect(isSafeShellName("zsh"));
    try testing.expect(isSafeShellName("dash"));
    try testing.expect(isSafeShellName("sh"));
    try testing.expect(isSafeShellName("fish"));
    try testing.expect(isSafeShellName("nu"));
    // Hyphens and digits in the middle are fine — `bash-5.2-fork`
    // and `zsh5` are realistic shell binary names; the latter
    // is allowed (only specific chars are blocked).
    try testing.expect(isSafeShellName("bash-fork"));
    try testing.expect(isSafeShellName("zsh5"));
}

test "isSafeShellName rejects shell-injection primitives (security)" {
    // The shell name from argv ends up unquoted inside an eval'd
    // snippet. Any character with a special meaning in /bin/sh
    // must be rejected so an attacker can't escape the
    // `exec atty <token>` context.
    try testing.expect(!isSafeShellName(""));
    try testing.expect(!isSafeShellName("; rm -rf /"));
    try testing.expect(!isSafeShellName("bash; echo pwned"));
    try testing.expect(!isSafeShellName("$(rm -rf ~)"));
    try testing.expect(!isSafeShellName("`whoami`"));
    try testing.expect(!isSafeShellName("'; evil; '"));
    try testing.expect(!isSafeShellName("bash space"));
    // Path-laden shell names also flunk — the test below pins
    // that. Users who genuinely need `/usr/bin/zsh` should use
    // `atty init` (no arg), which emits `exec atty` and falls
    // back to `$SHELL` at atty's end.
    try testing.expect(!isSafeShellName("/bin/bash"));
    try testing.expect(!isSafeShellName("./shell"));
    // Length cap — keep the allowlist tight.
    var long_buf: [33]u8 = .{'a'} ** 33;
    try testing.expect(!isSafeShellName(&long_buf));
}

test "isSafeShellName rejects leading dash — would parse as an atty flag" {
    // `atty init -h` would otherwise emit `exec atty -h`, which
    // atty's argv parser interprets as --help → atty prints usage
    // and exits, breaking the interactive shell that ran the
    // snippet. The leading-`-` rule blocks this even though all
    // the characters individually pass the allowlist.
    try testing.expect(!isSafeShellName("-h"));
    try testing.expect(!isSafeShellName("-V"));
    try testing.expect(!isSafeShellName("--help"));
    try testing.expect(!isSafeShellName("-bash"));
    // Mid-name `-` still allowed — e.g. `bash-fork`.
    try testing.expect(isSafeShellName("bash-fork"));
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
