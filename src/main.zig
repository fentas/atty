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
const debug_replay = atty.debug_replay;

// Shell snippets live in `src/snippets/*.sh` rather than inline
// Zig multi-line literals so shellcheck + editor highlighting
// work on the integration code. `@embedFile` bakes the bytes in
// at compile time — no runtime file I/O, same binary footprint.
const usage = @embedFile("snippets/usage.txt");

const shell_init_header_prefix = @embedFile("snippets/init_header_prefix.sh");

const shell_init_osc133_bash = @embedFile("snippets/init_osc133_bash.sh");

const shell_init_osc133_zsh = @embedFile("snippets/init_osc133_zsh.sh");

const shell_init_osc133_generic = @embedFile("snippets/init_osc133_generic.sh");

// ──────────────────────────────────────────────────────────────────────
// `atty doctor` — shell-agnostic health check.
//
// Emit as `eval "$(atty doctor)"` inside an atty session. Inspects the
// caller's shell state — env vars, PROMPT_COMMAND, PS1, function
// defs, bash vs zsh — and prints pass/fail for each step of the OSC
// 133 integration chain. The only knob atty itself can't reach from
// a child process (cumulative parser byte/dispatch counters) is
// already surfaced in the OSC 133 gate's error string, so the doctor
// concentrates on the shell side.
//
// Coloured output via ANSI SGR. `\e[32m✓\e[0m` / `\e[31m✗\e[0m` —
// trivially detectable, low visual noise. Heredoc-quoting is `'EOF'`
// (single-quoted) so the snippet's `$X` references survive the eval
// stage and land at runtime.
const shell_doctor_snippet = @embedFile("snippets/doctor.sh");

fn emitInitSnippet(shell: []const u8) void {
    writeStdout(shell_init_header_prefix);

    // Header continues with `    exec atty <shell>\nfi\n` — bake
    // the shell name in so the re-exec lands the same shell the
    // user named in `atty init <shell>` (not just $SHELL, which
    // may not match the rc file we're being eval'd from).
    //
    // SECURITY: the shell name comes from argv and ends up
    // unquoted inside a shell snippet the user will `eval`. An
    // attacker who can make the user run something like
    // `eval "$(atty init '; rm -rf ~; echo bash')"` would get
    // arbitrary code execution. We don't quote — we VALIDATE.
    // Only an alphanumeric/`_`/`-` token (with a sane length cap)
    // passes through; anything else falls back to the bare form
    // (no shell argument), which is harmless. The well-known
    // values `bash` and `zsh` are obviously fine; users who
    // genuinely need a path-laden shell can `atty init` (no arg)
    // and the snippet uses `exec atty` which falls back to
    // `$SHELL` at atty's end.
    const shell_safe = args_mod.isSafeShellName(shell);
    var buf: [256]u8 = undefined;
    const exec_line = if (shell_safe)
        std.fmt.bufPrint(&buf, "\n    exec atty {s}\nfi\n", .{shell}) catch "\n    exec atty\nfi\n"
    else
        "\n    exec atty\nfi\n";
    writeStdout(exec_line);

    if (shell_safe and std.mem.eql(u8, shell, "bash")) {
        writeStdout(shell_init_osc133_bash);
    } else if (shell_safe and std.mem.eql(u8, shell, "zsh")) {
        writeStdout(shell_init_osc133_zsh);
    } else {
        // No shell, unknown shell, OR unsafe shell name → fall back
        // to the dual-branch detection that picks at runtime. Bash
        // and zsh are covered inline; other shells (fish, nu, …)
        // need their own integration which we don't ship yet.
        writeStdout(shell_init_osc133_generic);
    }
}

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

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
        .print_init => |shell| {
            emitInitSnippet(shell);
            std.process.exit(0);
        },
        .print_doctor => {
            writeStdout(shell_doctor_snippet);
            std.process.exit(0);
        },
        .debug => |dargs| {
            std.process.exit(debug_replay.run(allocator, dargs));
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

    const stdin_tty = std.c.isatty(std.posix.STDIN_FILENO) != 0;
    const stdout_tty = std.c.isatty(std.posix.STDOUT_FILENO) != 0;
    const is_tty = stdin_tty and stdout_tty;

    // atty is a TTY-in-the-middle — pipes/redirected stdio leave
    // the proxy with no terminal to drive, and overlay writes to a
    // dead pipe accumulate as silently-swallowed `error.WriteFailed`
    // from the catch-all rendering paths. Refuse up front with an
    // actionable error rather than starting an interactive session
    // on an unusable terminal.
    //
    // `atty init` / `atty doctor` / `-V` / `-h` exit inside
    // parseArgs before this check, so init eval'd into a non-tty
    // context still works.
    if (!is_tty) {
        var buf: [512]u8 = undefined;
        const which: []const u8 = if (!stdin_tty and !stdout_tty)
            "stdin and stdout are"
        else if (!stdin_tty)
            "stdin is"
        else
            "stdout is";
        // ASCII-only message — the fallback is for terminals that
        // may not render UTF-8 (the case we're bailing on can leave
        // stderr pointed at a legacy pipe/log).
        //
        // `error:` prefix + exit(2) matches the parseArgs unknown-
        // flag pattern: both are usage failures.
        const msg = std.fmt.bufPrint(&buf, "error: {s} not a terminal.\n" ++
            "  atty wraps a shell for interactive use; pipes/redirected stdio leave the\n" ++
            "  proxy with no terminal to drive. Run atty directly from an interactive\n" ++
            "  terminal, not through pipes or shell redirections.\n", .{which}) catch
            "error: stdio is not a terminal.\n";
        writeStderr(msg);
        std.process.exit(2);
    }

    const info = try atty.proxy.run(allocator, io, .{
        .argv = argv,
        .is_tty = is_tty,
    });

    std.process.exit(info.exit_code);
}
