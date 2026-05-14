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
    \\  atty init [shell]     print shell-integration snippet
    \\                          (use as: eval "$(atty init bash)")
    \\
    \\Flags:
    \\  -h, --help            Print this help
    \\  -V, --version         Print version and exit
    \\
    \\Module composition is configured at build time via src/config.zig.
    \\Use `-Dconfig=path` to point zig build at a different config file.
    \\
;

const shell_init_header_prefix =
    \\# atty shell integration — drop this in your .bashrc / .zshrc:
    \\#   eval "$(atty init bash)"
    \\#
    \\# Re-execs the current interactive shell under atty. atty
    \\# injects ATTY=1 (and ATTY_PID / ATTY_VERSION) into the child
    \\# shell's environment, so nested invocations — atty's own
    \\# child, or any subshell it spawns — skip the exec and fall
    \\# through to the OSC 133 setup. Only fires for TTY-attached
    \\# interactive shells; scripts run unchanged.
    \\if [ -z "${ATTY:-}" ] && [ -t 0 ] && [ -t 1 ]; then
;

const shell_init_osc133_bash =
    \\
    \\# OSC 133 prompt markers — tell atty (and Ghostty / VS Code /
    \\# iTerm / …) where prompts start (A), where user input begins
    \\# (B), and where commands finish (D + exit code). atty uses
    \\# A/B to capture the user's typed line for accurate history
    \\# recall; without these it falls back to keystroke tracking,
    \\# which loses fidelity on completion and multi-line edits.
    \\#
    \\# `__atty_osc133_wrap_ps1` is run from PROMPT_COMMAND so it
    \\# re-applies the `;A` / `;B` wrap on every cycle. Prompt
    \\# managers like Starship overwrite PS1 inside their own
    \\# precmd; a one-shot `PS1=…;A…;B…` at init time gets blown
    \\# away on the first redraw. Idempotent: if the wrap is
    \\# already on PS1 we return, so users without a prompt
    \\# manager don't pay re-wrapping cost.
    \\__atty_osc133_d() { local __code=$?; printf '\033]133;D;%s\007' "$__code"; }
    \\__atty_osc133_wrap_ps1() {
    \\    # Skip ONLY when both `;A` and `;B` are already in PS1
    \\    # (in order) — that's atty's wrap signature. A partial
    \\    # integration that injected `;A` alone (Ghostty's
    \\    # `shell-integration-features = osc-133` does this for
    \\    # some shells) would otherwise short-circuit us and atty
    \\    # would never get its `;B` input-region marker, which is
    \\    # what the OSC 133 tracker actually keys on for accurate
    \\    # input capture.
    \\    case "$PS1" in
    \\        *$'\033]133;A\007'*$'\033]133;B\007'*) return ;;
    \\    esac
    \\    PS1=$'\\[\033]133;A\007\\]'"${PS1}"$'\\[\033]133;B\007\\]'
    \\}
    \\PROMPT_COMMAND="__atty_osc133_d${PROMPT_COMMAND:+;}${PROMPT_COMMAND:-};__atty_osc133_wrap_ps1"
    \\__atty_osc133_wrap_ps1
    \\
;

const shell_init_osc133_zsh =
    \\
    \\# OSC 133 prompt markers — tell atty (and Ghostty / VS Code /
    \\# iTerm / …) where prompts start (A), where user input begins
    \\# (B), where commands run (C), and where they finish (D + exit
    \\# code). atty uses A/B to capture the user's typed line for
    \\# accurate history recall; without these it falls back to
    \\# keystroke tracking, which loses fidelity on completion and
    \\# multi-line edits.
    \\__atty_osc133_precmd() {
    \\    local __code=$?
    \\    printf '\e]133;D;%s\a' "$__code"
    \\    printf '\e]133;A\a'
    \\}
    \\__atty_osc133_preexec() { printf '\e]133;C\a'; }
    \\autoload -Uz add-zsh-hook
    \\add-zsh-hook precmd __atty_osc133_precmd
    \\add-zsh-hook preexec __atty_osc133_preexec
    \\PS1+=$'%{\e]133;B\a%}'
    \\
;

const shell_init_osc133_generic =
    \\
    \\# OSC 133 prompt markers — see `atty init bash` or `atty init zsh`
    \\# for shell-specific hooks. atty falls back to keystroke
    \\# tracking when these aren't emitted.
    \\if [ -n "${BASH_VERSION:-}" ]; then
    \\    __atty_osc133_d() { local __code=$?; printf '\033]133;D;%s\007' "$__code"; }
    \\    PROMPT_COMMAND="__atty_osc133_d${PROMPT_COMMAND:+;}${PROMPT_COMMAND:-}"
    \\    PS1=$'\\[\033]133;A\007\\]'"${PS1}"$'\\[\033]133;B\007\\]'
    \\elif [ -n "${ZSH_VERSION:-}" ]; then
    \\    __atty_osc133_precmd() {
    \\        local __code=$?
    \\        printf '\e]133;D;%s\a' "$__code"
    \\        printf '\e]133;A\a'
    \\    }
    \\    __atty_osc133_preexec() { printf '\e]133;C\a'; }
    \\    autoload -Uz add-zsh-hook
    \\    add-zsh-hook precmd __atty_osc133_precmd
    \\    add-zsh-hook preexec __atty_osc133_preexec
    \\    PS1+=$'%{\e]133;B\a%}'
    \\fi
    \\
;

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
        .print_init => |shell| {
            emitInitSnippet(shell);
            std.process.exit(0);
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
