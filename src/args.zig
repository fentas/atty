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
    /// `atty debug <verb> [args…]` — debug-capture tooling (see the `debug`
    /// config + Alt+Shift+D). The payload is the tokens AFTER `debug` (e.g.
    /// ["replay", "<report>", "--fast"]), so the debug module owns its own
    /// verb/flag parsing. Allocator-owned (duped); free with `freeDebug`.
    /// main.zig exits after handling, so it skips the free; tests must free.
    debug: [][]const u8,
};

/// Free the allocator-owned shell string carried by `.print_init`.
/// Safe to call with the empty default (no-op when the slice is
/// zero-length and `&.{}`-backed; otherwise frees normally).
pub fn freePrintInit(allocator: std.mem.Allocator, shell: []const u8) void {
    if (shell.len > 0) allocator.free(shell);
}

/// Free the allocator-owned token slice carried by `.debug`.
pub fn freeDebug(allocator: std.mem.Allocator, argv: [][]const u8) void {
    for (argv) |s| allocator.free(s);
    allocator.free(argv);
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
            positional = .empty; // deinit leaves it undefined; keep the fn-level errdefer safe if the dupe below OOMs
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
        // `atty debug <verb> …` — same positional-subcommand shape. Capture the
        // rest of the tokens for the debug module to parse.
        if (std.mem.eql(u8, a, "debug") and positional.items.len == 0) {
            for (positional.items) |s| allocator.free(s);
            positional.deinit(allocator);
            positional = .empty; // deinit leaves it undefined; keep the fn-level errdefer safe if the appends below OOM
            var rest: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (rest.items) |s| allocator.free(s);
                rest.deinit(allocator);
            }
            var j = i + 1;
            while (j < args.len) : (j += 1) try rest.append(allocator, try allocator.dupe(u8, args[j]));
            return .{ .debug = try rest.toOwnedSlice(allocator) };
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
// Tests — extracted to `args_tests.zig` for readability.
// ===========================================================================

test {
    _ = @import("args_tests.zig");
}
