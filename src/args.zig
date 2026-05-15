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
    /// `atty init [shell]` — print the shell-integration snippet
    /// to stdout and exit. Used as `eval "$(atty init bash)"` from
    /// the user's `.bashrc` / `.zshrc`. The optional shell argument
    /// is preserved in the snippet's `exec atty <shell>` so the
    /// re-exec runs the same shell the user named — important when
    /// `$SHELL` doesn't match the .{bash,zsh}rc that's evaluating
    /// us. Empty string = no shell given, snippet emits bare `exec
    /// atty` (which falls back to $SHELL at atty's end).
    ///
    /// **Ownership**: the payload is allocator-owned (duped from
    /// the caller's argv to match the contract of `.ok.positional`).
    /// Free with `freePrintInit(allocator, shell)` when you're
    /// done. `main.zig` skips the free because it exits immediately
    /// after emitting the snippet; tests must free explicitly.
    print_init: []const u8,
    /// `atty doctor` — print a shell snippet to stdout that, when
    /// evaluated, inspects the calling shell's state and prints
    /// pass/fail for each integration check (OSC 133 hooks defined,
    /// PROMPT_COMMAND wired, PS1 wrapped, $ATTY set, …). Used via
    /// `eval "$(atty doctor)"` from inside an atty session when the
    /// OSC 133 gate keeps firing — pinpoints which step of the
    /// integration chain is broken without rebuilding the binary.
    print_doctor,
};

/// Free the allocator-owned shell string carried by `.print_init`.
/// Safe to call with the empty default (no-op when the slice is
/// zero-length and `&.{}`-backed; otherwise frees normally).
pub fn freePrintInit(allocator: std.mem.Allocator, shell: []const u8) void {
    if (shell.len > 0) allocator.free(shell);
}

pub fn parseArgv(allocator: std.mem.Allocator, args: []const []const u8) !ParseOutcome {
    var positional: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (positional.items) |s| allocator.free(s);
        positional.deinit(allocator);
    }

    var done_with_flags = false;

    for (args, 0..) |a, i| {
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
        // Special-case the `init` subcommand: `atty init [shell]`
        // prints the shell-integration snippet to stdout. Has to
        // come *before* we treat the first positional as a shell
        // name — otherwise it'd be interpreted as "spawn `init` as
        // the shell." A user who genuinely has a shell binary
        // named `init` can still reach it via `atty -- init`.
        // The next token (if any) names the shell so the emitted
        // snippet can do `exec atty <shell>` and match the rc file
        // it's being eval'd from. Duped from the caller's argv so
        // ownership is consistent with `.ok.positional` and
        // independent of argv lifetime; see `freePrintInit`.
        if (std.mem.eql(u8, a, "init") and positional.items.len == 0) {
            for (positional.items) |s| allocator.free(s);
            positional.deinit(allocator);
            const shell_name: []const u8 = if (i + 1 < args.len)
                try allocator.dupe(u8, args[i + 1])
            else
                "";
            return .{ .print_init = shell_name };
        }
        // `atty doctor` — same shape as `init`: positional, must
        // come before any shell-name positional. The doctor snippet
        // is shell-agnostic (works in bash and zsh) and takes no
        // arguments. A user with a shell named `doctor` can still
        // run it via `atty -- doctor`.
        if (std.mem.eql(u8, a, "doctor") and positional.items.len == 0) {
            for (positional.items) |s| allocator.free(s);
            positional.deinit(allocator);
            return .print_doctor;
        }
        // First positional ends flag parsing.
        try positional.append(allocator, try allocator.dupe(u8, a));
        done_with_flags = true;
    }

    return .{ .ok = .{ .positional = try positional.toOwnedSlice(allocator) } };
}

/// Restrict the shell argument from `atty init <shell>` to a small
/// allowlist character set before main.zig pastes it into the
/// emitted `eval`'d snippet. ASCII letters (both cases), digits,
/// `_`, `-` only; max 32 bytes; MUST NOT start with `-`. Anything
/// else (spaces, semicolons, quotes, backticks, `$`, …) flunks
/// and the caller falls back to the no-shell form. Shell-
/// injection defence in depth — the typical caller passes
/// "bash" / "zsh", which both pass.
///
/// The no-leading-`-` rule matters because the token ends up
/// pasted into `exec atty <shell>` unquoted. A leading-dash value
/// like `-h` would otherwise turn into an atty flag rather than
/// a shell name and atty's argv parser would print --help and
/// exit, breaking the interactive shell.
pub fn isSafeShellName(s: []const u8) bool {
    if (s.len == 0 or s.len > 32) return false;
    if (s[0] == '-') return false;
    for (s) |b| {
        const ok = (b >= 'a' and b <= 'z') or
            (b >= 'A' and b <= 'Z') or
            (b >= '0' and b <= '9') or
            b == '_' or b == '-';
        if (!ok) return false;
    }
    return true;
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
