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
    \\  atty doctor           print health-check snippet
    \\                          (use as: eval "$(atty doctor)")
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
    \\__atty_osc133_d() {
    \\    # PRESERVE the user's command exit code through the hook —
    \\    # other PROMPT_COMMAND consumers (direnv, starship, zoxide,
    \\    # …) inspect `$?` to render "last command status" /
    \\    # conditional output. Without the explicit `return`,
    \\    # `printf`'s exit code (0 unless the write failed) would
    \\    # shadow the real exit code and every command would look
    \\    # successful to downstream hooks.
    \\    local __code=$?
    \\    printf '\033]133;D;%s\007' "$__code"
    \\    return "$__code"
    \\}
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
    \\# bash 5.1+ supports PROMPT_COMMAND as an array. Prompt
    \\# managers (starship, oh-my-posh, p10k…) typically switch it to
    \\# array form on 5.1+ AND replace PS1 inside their own precmd.
    \\# For atty's wrap to survive, it MUST run AFTER theirs — which
    \\# means appending it as a separate array element rather than
    \\# semicolon-chaining inside whatever element[0] happens to be.
    \\# String form (bash <5.1, or 5.1+ where no manager has switched
    \\# PROMPT_COMMAND to array yet) keeps the original semicolon
    \\# concat — correct in that mode.
    \\# `;C` (command-start marker) is emitted from a DEBUG trap —
    \\# bash has no native preexec hook, so we synthesise one. The
    \\# trap fires for every simple command bash executes; we gate
    \\# emission so only the FIRST simple command of each logical
    \\# user-typed command produces `;C`. Without this gate ;C would
    \\# fire many times per prompt cycle (every function call in
    \\# PROMPT_COMMAND, every pipeline component, every subshell).
    \\#
    \\# The flag is reset at the END of PROMPT_COMMAND so the next
    \\# user command re-arms emission. Existing DEBUG traps
    \\# (starship's `_starship_set_return`, atuin's
    \\# `__atuin_preexec`, etc.) are chained — atty's trap APPENDS
    \\# its body rather than overwriting, so prompt-manager exit-
    \\# code capture and history-tracking hooks keep firing.
    \\__atty_osc133_c_emitted=1
    \\__atty_osc133_preexec() {
    \\    # Skip inside readline completion subshells (bash sets
    \\    # COMP_LINE while running completion functions). Without
    \\    # this guard ;C fires during Tab-completion expansion,
    \\    # which the proxy then sees as "user just ran a command"
    \\    # — confuses the OSC 133 state machine.
    \\    [[ -n "${COMP_LINE-}" ]] && return
    \\    (( __atty_osc133_c_emitted )) && return
    \\    __atty_osc133_c_emitted=1
    \\    printf '\033]133;C\007'
    \\}
    \\__atty_osc133_reset_c() { __atty_osc133_c_emitted=0; }
    \\__atty_osc133_setup_debug_trap() {
    \\    # Idempotency: skip if atty's preexec is already chained.
    \\    case "$(trap -p DEBUG 2>/dev/null)" in
    \\        *__atty_osc133_preexec*) return ;;
    \\    esac
    \\    local existing
    \\    existing="$(trap -p DEBUG 2>/dev/null)"
    \\    if [[ -z "$existing" ]]; then
    \\        trap '__atty_osc133_preexec' DEBUG
    \\    else
    \\        # `trap -p DEBUG` outputs `trap -- 'BODY' DEBUG` —
    \\        # strip the wrapping to extract BODY for chaining.
    \\        # Single-quote embedded in BODY would break this
    \\        # parse, but no shipped tool's DEBUG trap body
    \\        # contains quoted bodies in practice (starship,
    \\        # atuin, bash-preexec all use plain function calls).
    \\        existing="${existing#trap -- \'}"
    \\        existing="${existing%\' DEBUG}"
    \\        trap "${existing}; __atty_osc133_preexec" DEBUG
    \\    fi
    \\}
    \\if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
    \\    PROMPT_COMMAND=("__atty_osc133_d" "${PROMPT_COMMAND[@]}" "__atty_osc133_wrap_ps1" "__atty_osc133_reset_c")
    \\else
    \\    PROMPT_COMMAND="__atty_osc133_d${PROMPT_COMMAND:+;}${PROMPT_COMMAND:-};__atty_osc133_wrap_ps1;__atty_osc133_reset_c"
    \\fi
    \\__atty_osc133_setup_debug_trap
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
const shell_doctor_snippet =
    \\# atty doctor — paste into your shell:  eval "$(atty doctor)"
    \\__atty_doctor_ok()   { printf '  \033[32m✓\033[0m  %s\n' "$*"; }
    \\__atty_doctor_fail() { printf '  \033[31m✗\033[0m  %s\n' "$*"; }
    \\__atty_doctor_warn() { printf '  \033[33m!\033[0m  %s\n' "$*"; }
    \\__atty_doctor_pass=0
    \\__atty_doctor_fail_count=0
    \\__atty_doctor_check() {
    \\    if eval "$1"; then __atty_doctor_ok "$2"; __atty_doctor_pass=$((__atty_doctor_pass+1));
    \\    else __atty_doctor_fail "$2 — $3"; __atty_doctor_fail_count=$((__atty_doctor_fail_count+1)); fi
    \\}
    \\printf '\033[1matty doctor\033[0m — OSC 133 integration check\n\n'
    \\__atty_doctor_check '[ -n "${ATTY:-}" ]' \
    \\    'inside atty session ($ATTY set)' \
    \\    'not running under atty — start a new shell with `atty bash`'
    \\if [ -n "${BASH_VERSION:-}" ]; then
    \\    __atty_doctor_ok "shell: bash $BASH_VERSION"
    \\    # bash 5.1+ supports PROMPT_COMMAND-as-array. Mention this
    \\    # in the doctor output (informational, not a failure — atty's
    \\    # init handles both forms since the array-aware fix). If
    \\    # `wrap_ps1` is at the END of the array we're good; if it's
    \\    # embedded inside an earlier element (legacy/broken state
    \\    # from a pre-fix install), later checks for `;A` / `;B` in
    \\    # PS1 will surface the real failure.
    \\    if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
    \\        __atty_doctor_ok "PROMPT_COMMAND is an array (bash 5.1+, prompt manager active) — atty's init handles this"
    \\    fi
    \\    __atty_doctor_check 'declare -F __atty_osc133_d > /dev/null' \
    \\        '__atty_osc133_d function defined' \
    \\        'init eval was run OUTSIDE atty — its `exec atty bash` replaced your shell and discarded the function defs. Either add `eval "$(atty init bash)"` to your ~/.bashrc, or run it AGAIN now inside this session (ATTY=1 skips the exec, sets up OSC 133 in-place)'
    \\    __atty_doctor_check 'declare -F __atty_osc133_wrap_ps1 > /dev/null' \
    \\        '__atty_osc133_wrap_ps1 function defined' \
    \\        'same as above — re-run `eval "$(atty init bash)"` inside this atty session'
    \\    # `${PROMPT_COMMAND[*]}` flattens both string and array
    \\    # forms — array elements get joined by the first char of
    \\    # IFS (space by default), which is enough for substring
    \\    # matching. Plain `${PROMPT_COMMAND:-}` would return only
    \\    # the first array element and silently miss our wrap when
    \\    # it lives as a separate (final) element.
    \\    __atty_doctor_check 'case "${PROMPT_COMMAND[*]:-}" in *__atty_osc133_d*) true ;; *) false ;; esac' \
    \\        'PROMPT_COMMAND wired to __atty_osc133_d' \
    \\        'something overwrote PROMPT_COMMAND after the init eval (.bashrc / prompt manager?)'
    \\    __atty_doctor_check 'case "${PROMPT_COMMAND[*]:-}" in *__atty_osc133_wrap_ps1*) true ;; *) false ;; esac' \
    \\        'PROMPT_COMMAND wired to __atty_osc133_wrap_ps1' \
    \\        'same as above — PROMPT_COMMAND was reassigned'
    \\    __atty_doctor_check 'case "${PS1:-}" in *$(printf "\033]133;A\007")*) true ;; *) false ;; esac' \
    \\        'PS1 contains `;A` prompt-start marker' \
    \\        'wrap_ps1 never ran on the current prompt (try pressing Enter once)'
    \\    __atty_doctor_check 'case "${PS1:-}" in *$(printf "\033]133;B\007")*) true ;; *) false ;; esac' \
    \\        'PS1 contains `;B` input-region marker' \
    \\        'same as above — wrap_ps1 not yet applied'
    \\    __atty_doctor_check 'declare -F __atty_osc133_preexec > /dev/null' \
    \\        '__atty_osc133_preexec function defined (emits `;C`)' \
    \\        'init eval ran with an older atty binary that lacked the DEBUG-trap-based `;C` emitter. Re-run after upgrading atty — dialog/auto mode needs `;C` to advance past `.executing` state.'
    \\    __atty_doctor_check 'case "$(trap -p DEBUG 2>/dev/null)" in *__atty_osc133_preexec*) true ;; *) false ;; esac' \
    \\        'DEBUG trap wired to __atty_osc133_preexec' \
    \\        'something replaced the DEBUG trap after init (a later loaded plugin?) — dialog will stall in `.executing` until the trap is restored. Re-run `eval "$(atty init bash)"` AFTER all plugins finish setting up traps.'
    \\elif [ -n "${ZSH_VERSION:-}" ]; then
    \\    __atty_doctor_ok "shell: zsh $ZSH_VERSION"
    \\    __atty_doctor_check 'typeset -f __atty_osc133_precmd > /dev/null' \
    \\        '__atty_osc133_precmd function defined' \
    \\        'did you run `eval "$(atty init zsh)"` yet?'
    \\    __atty_doctor_check 'typeset -f __atty_osc133_preexec > /dev/null' \
    \\        '__atty_osc133_preexec function defined' \
    \\        'did you run `eval "$(atty init zsh)"` yet?'
    \\    __atty_doctor_check '(( ${precmd_functions[(I)__atty_osc133_precmd]} ))' \
    \\        'precmd hook installed' \
    \\        'add-zsh-hook precmd never ran — re-run the eval'
    \\    __atty_doctor_check '(( ${preexec_functions[(I)__atty_osc133_preexec]} ))' \
    \\        'preexec hook installed' \
    \\        'add-zsh-hook preexec never ran — re-run the eval'
    \\else
    \\    __atty_doctor_warn 'unknown shell — only bash and zsh are first-class. Press `Alt+A` for single-shot LLM, dialog/auto modes need OSC 133.'
    \\fi
    \\printf '\n'
    \\if [ "$__atty_doctor_fail_count" -eq 0 ]; then
    \\    printf '\033[32mall checks passed.\033[0m if `Alt+S` still fails, the OSC 133 gate error includes a \033[1mbytes=N dispatches=M\033[0m diagnostic — `dispatches>0` means atty IS seeing markers; `dispatches=0` means the shell never emitted any (even though the hooks look wired — try `set | grep PROMPT`)\n'
    \\else
    \\    printf '\033[31m%d check(s) failed.\033[0m fix the items above (most often: re-run the init eval AFTER your .bashrc / prompt manager has finished setting up PROMPT_COMMAND)\n' "$__atty_doctor_fail_count"
    \\fi
    \\unset -f __atty_doctor_ok __atty_doctor_fail __atty_doctor_warn __atty_doctor_check 2>/dev/null
    \\unset __atty_doctor_pass __atty_doctor_fail_count
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
        .print_doctor => {
            writeStdout(shell_doctor_snippet);
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

    const stdin_tty = isatty(std.posix.STDIN_FILENO) != 0;
    const stdout_tty = isatty(std.posix.STDOUT_FILENO) != 0;
    const is_tty = stdin_tty and stdout_tty;

    // Refuse to run when stdio isn't an interactive terminal on both
    // sides. atty is a TTY-in-the-middle: its model assumes a real
    // user typing into a real terminal. Piping its stdin or stdout
    // (`echo x | atty bash`, `atty bash | head -1`) leaves the proxy
    // forwarding shell output into a dead pipe — reproduces as a
    // 100%-CPU runaway when the pipe peer exits and atty's writes
    // start hitting EPIPE without anything to drive a clean shutdown.
    // The shipped writeFully (`src/proxy/io.zig`) now surfaces EPIPE
    // promptly, but the resulting "crashes on startup" is a worse UX
    // than a clear refusal up front.
    if (!is_tty) {
        var buf: [512]u8 = undefined;
        const which: []const u8 = if (!stdin_tty and !stdout_tty)
            "stdin and stdout are"
        else if (!stdin_tty)
            "stdin is"
        else
            "stdout is";
        const msg = std.fmt.bufPrint(&buf, "atty: refusing to run — {s} not a terminal.\n" ++
            "  atty wraps a shell for interactive use; pipes/redirected stdio leave the\n" ++
            "  proxy with no terminal to drive. Run atty directly from an interactive\n" ++
            "  terminal, not through pipes or shell redirections.\n", .{which}) catch
            "atty: refusing to run — stdio is not a terminal.\n";
        writeStderr(msg);
        std.process.exit(1);
    }

    // Ignore SIGPIPE so a transient write to a half-closed fd
    // (overlay writes after the user detaches the terminal, a kill
    // -HUP race against the slave) surfaces as `error.WriteFailed`
    // via `writeFully`'s errno gate — never as silent termination.
    // Zig's startup historically catches SIGPIPE on Linux, but
    // pinning the disposition here decouples atty from that
    // implementation detail.
    {
        const sa = std.posix.Sigaction{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.PIPE, &sa, null);
    }

    const info = try atty.proxy.run(allocator, io, .{
        .argv = argv,
        .is_tty = is_tty,
    });

    std.process.exit(info.exit_code);
}
