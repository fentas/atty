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
    \\printf '\033[1matty doctor\033[0m — OSC 133 integration\n\n'
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
    \\    # Bash scopes DEBUG/RETURN traps PER-FUNCTION unless `set -T`
    \\    # is active globally — inside `__atty_doctor_check` (which is
    \\    # what runs `eval "$1"`), `trap -p DEBUG` returns the empty
    \\    # function-local trap, never the user's shell-level one.
    \\    # Capture the trap state HERE in the outer scope and pass it
    \\    # into the check as a variable, so the case-match happens on
    \\    # data instead of re-querying from inside a function frame.
    \\    __atty_doctor_dbg_trap="$(trap -p DEBUG 2>/dev/null)"
    \\    __atty_doctor_check 'case "$__atty_doctor_dbg_trap" in *__atty_osc133_preexec*) true ;; *) false ;; esac' \
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
    \\
    \\# atty-guard sidecar — security_guard's optional V2-* backend.
    \\# Each check is non-fatal: a fresh atty install runs fine with
    \\# the in-proc Tier-1 only (no daemon). The checks fire only
    \\# when there's evidence the operator INTENDED to install the
    \\# sidecar (system binary present OR system unit installed);
    \\# otherwise the section is silent. The doctor knows about both
    \\# the system-daemon install (post-#140 default) AND the legacy
    \\# systemd-user install (pre-#140 — flagged with a one-line
    \\# migration nudge).
    \\__atty_doctor_guard_bin=""
    \\if command -v atty-guard >/dev/null 2>&1; then
    \\    __atty_doctor_guard_bin="$(command -v atty-guard)"
    \\elif [ -x /usr/local/bin/atty-guard ]; then
    \\    __atty_doctor_guard_bin="/usr/local/bin/atty-guard"
    \\elif [ -x "$HOME/.local/bin/atty-guard" ]; then
    \\    __atty_doctor_guard_bin="$HOME/.local/bin/atty-guard"
    \\fi
    \\__atty_doctor_guard_unit_sys=/etc/systemd/system/atty-guard.service
    \\__atty_doctor_guard_unit_user="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/atty-guard.service"
    \\__atty_doctor_guard_unit=""
    \\__atty_doctor_guard_mode=""
    \\if [ -f "$__atty_doctor_guard_unit_sys" ]; then
    \\    __atty_doctor_guard_unit="$__atty_doctor_guard_unit_sys"
    \\    __atty_doctor_guard_mode=system
    \\elif [ -f "$__atty_doctor_guard_unit_user" ]; then
    \\    __atty_doctor_guard_unit="$__atty_doctor_guard_unit_user"
    \\    __atty_doctor_guard_mode=user
    \\fi
    \\if [ -n "$__atty_doctor_guard_bin" ] || [ -n "$__atty_doctor_guard_unit" ]; then
    \\    printf '\n\033[1matty doctor\033[0m — atty-guard sidecar\n\n'
    \\    if [ "$__atty_doctor_guard_mode" = "user" ]; then
    \\        # Pre-#140 install. Still works for the bundled-corpus
    \\        # path but doesn't have the dedicated `atty` user / file
    \\        # ownership protections. Nudge to migrate but don't fail
    \\        # the check.
    \\        __atty_doctor_warn 'systemd-user install detected (pre-#140). Migrate to the system-daemon install by running `sudo make install-guard` from the atty source tree — moves atty-guard under a dedicated `atty` user with permission-checked atom files at /var/lib/atty-guard/.'
    \\    fi
    \\    if [ -n "$__atty_doctor_guard_bin" ]; then
    \\        __atty_doctor_guard_bin_label="atty-guard binary present ($__atty_doctor_guard_bin)"
    \\    else
    \\        __atty_doctor_guard_bin_label="atty-guard binary present"
    \\    fi
    \\    __atty_doctor_check '[ -n "'"$__atty_doctor_guard_bin"'" ]' \
    \\        "$__atty_doctor_guard_bin_label" \
    \\        'install with `sudo make install-guard` (from the atty source tree) or download the binary from https://github.com/fentas/atty/releases'
    \\    __atty_doctor_check '[ -f "'"$__atty_doctor_guard_unit_sys"'" ] || [ -f "'"$__atty_doctor_guard_unit_user"'" ]' \
    \\        'atty-guard.service unit installed' \
    \\        '`sudo make install-guard` writes the system unit to /etc/systemd/system/ and enables it'
    \\    if command -v systemctl >/dev/null 2>&1; then
    \\        if [ "$__atty_doctor_guard_mode" = "system" ]; then
    \\            __atty_doctor_check 'systemctl is-active --quiet atty-guard.service 2>/dev/null' \
    \\                'atty-guard.service is active' \
    \\                'sudo systemctl start atty-guard.service (check `systemctl status atty-guard` for the actual reason if it refuses)'
    \\        else
    \\            __atty_doctor_check 'systemctl --user is-active --quiet atty-guard.service 2>/dev/null' \
    \\                'atty-guard.service is active (systemd-user — legacy)' \
    \\                'systemctl --user start atty-guard.service (and consider migrating to the system install per the warning above)'
    \\        fi
    \\    fi
    \\    # Socket path differs by install mode. System daemon binds
    \\    # /run/atty-guard/atty-guard.sock (atty:atty 0750 group-
    \\    # readable). Legacy systemd-user binds under $XDG_RUNTIME_DIR
    \\    # or /tmp/atty-guard-<uid>.sock.
    \\    if [ "$__atty_doctor_guard_mode" = "system" ]; then
    \\        __atty_doctor_guard_sock=/run/atty-guard/atty-guard.sock
    \\    elif [ -n "${XDG_RUNTIME_DIR-}" ]; then
    \\        __atty_doctor_guard_sock="$XDG_RUNTIME_DIR/atty-guard.sock"
    \\    else
    \\        __atty_doctor_guard_sock="/tmp/atty-guard-$(id -u).sock"
    \\    fi
    \\    __atty_doctor_check '[ -S "'"$__atty_doctor_guard_sock"'" ]' \
    \\        "UDS socket reachable ($__atty_doctor_guard_sock)" \
    \\        'service started but socket missing — likely a permission or path mismatch; the daemon prints the bind error to journald on startup'
    \\    if [ "$__atty_doctor_guard_mode" = "system" ]; then
    \\        # System-daemon mode requires the user to be in the
    \\        # `atty` group to connect to the socket.
    \\        if id -nG 2>/dev/null | grep -qw atty; then
    \\            __atty_doctor_ok 'user is in `atty` group (can connect to the daemon socket)'
    \\        else
    \\            __atty_doctor_fail 'user not in `atty` group' 'sudo usermod -aG atty $USER; then log out + back in (or `newgrp atty` for a single shell)'
    \\        fi
    \\    fi
    \\    # Atom corpus check intentionally NOT done here. atty-guard's
    \\    # AtomMatcher reads its corpus via `include_str!` at compile
    \\    # time — there is no runtime atom file the daemon loads
    \\    # today. The optional `--update-atoms-now` writes to
    \\    # $XDG_DATA_HOME but the daemon ignores that file. Checking
    \\    # for it would either fail (file absent) for users on a
    \\    # bundled-only install (the supported path), or pass (file
    \\    # present) but mislead — the file's existence has no effect
    \\    # on detection. Runtime atom loading is on the post-#139
    \\    # roadmap; the doctor check returns when it's wired up.
    \\    # eBPF feature detection — uses `atty-guard --print-features`
    \\    # (post-issue-#145) which emits one Cargo feature per line.
    \\    # This is the authoritative probe: each feature name comes
    \\    # from a `#[cfg(feature = ...)]` block at compile time so the
    \\    # output is exactly the set baked into the running binary.
    \\    # Falls back to "unknown" for older binaries that don't
    \\    # support the flag (pre-issue-#145 installs).
    \\    if [ -n "$__atty_doctor_guard_bin" ]; then
    \\        # Three-state eBPF check, in order:
    \\        #   1. Binary doesn't support --print-features
    \\        #      (pre-issue-#145 install). Surface as a warn,
    \\        #      can't tell whether eBPF is compiled.
    \\        #   2. Feature is compiled BUT the unit's ExecStart
    \\        #      doesn't pass --enable-ebpf. Compiled but inert;
    \\        #      point at `sudo make install-guard GUARD_FEATURES=ebpf`.
    \\        #   3. Feature compiled + unit has --enable-ebpf.
    \\        #      Then check journald for the "eBPF attached"
    \\        #      line — green if found, warn (with the actual
    \\        #      error line) if not.
    \\        #
    \\        # Pipes the `--print-features` output DIRECTLY into
    \\        # grep — capturing into a shell var collapses newlines
    \\        # to spaces, breaking `grep -qx` for multi-feature
    \\        # builds.
    \\        "$__atty_doctor_guard_bin" --print-features >/dev/null 2>&1
    \\        __atty_doctor_guard_features_rc=$?
    \\        if [ $__atty_doctor_guard_features_rc -ne 0 ]; then
    \\            __atty_doctor_warn 'eBPF feature: cannot detect (atty-guard does not support --print-features — upgrade your atty-guard install for definitive feature reporting)'
    \\        elif "$__atty_doctor_guard_bin" --print-features 2>/dev/null | grep -qx ebpf; then
    \\            # Check whether the running unit was configured to
    \\            # actually load the BPF programs. ExecStart must
    \\            # carry `--enable-ebpf`; without it the daemon
    \\            # skips the loader regardless of the feature being
    \\            # baked in. Read from the live systemd state to
    \\            # honour any drop-in (the ebpf.conf installed by
    \\            # `install.sh --with-ebpf` lives at
    \\            # /etc/systemd/system/atty-guard.service.d/).
    \\            __atty_doctor_guard_execstart="$(systemctl show atty-guard.service -p ExecStart --value 2>/dev/null || true)"
    \\            if echo "$__atty_doctor_guard_execstart" | grep -q -- '--enable-ebpf'; then
    \\                # Look for the daemon's "eBPF attached" log
    \\                # line in the last 24h. If absent, surface
    \\                # whatever error landed instead (typically
    \\                # `eBPF unavailable — <reason>`).
    \\                if [ "$__atty_doctor_guard_mode" = "user" ]; then
    \\                    __atty_doctor_guard_journal_cmd='journalctl --user -u atty-guard.service --since=24h'
    \\                else
    \\                    __atty_doctor_guard_journal_cmd='sudo journalctl -u atty-guard.service --since=24h'
    \\                fi
    \\                if eval "$__atty_doctor_guard_journal_cmd" 2>/dev/null | grep -q 'eBPF attached'; then
    \\                    __atty_doctor_ok 'eBPF: compiled + ExecStart --enable-ebpf + journald shows "eBPF attached"'
    \\                else
    \\                    __atty_doctor_warn "eBPF: compiled + ExecStart has --enable-ebpf BUT journald shows no 'eBPF attached' in the last 24h. Run \`$__atty_doctor_guard_journal_cmd | grep -i ebpf\` to see the actual reason (typical: kernel lacks BPF LSM, daemon lacks CAP_BPF, or the .bpf.o object isn't on the loader's search path)."
    \\                fi
    \\            else
    \\                __atty_doctor_warn 'eBPF: compiled in BUT ExecStart does NOT pass --enable-ebpf. The drop-in at /etc/systemd/system/atty-guard.service.d/ebpf.conf is missing — install via `sudo make install-guard GUARD_FEATURES=tier2-onnx,osv-live,atoms-fetch,ebpf`'
    \\            fi
    \\        else
    \\            __atty_doctor_warn 'eBPF feature: NOT compiled in. Rebuild atty-guard with `make build-guard GUARD_FEATURES=...,ebpf` then `sudo make install-guard GUARD_FEATURES=...,ebpf` to wire the drop-in. Optional — V2-A in-memory threat-map is the fallback.'
    \\        fi
    \\    fi
    \\fi
    \\printf '\n'
    \\if [ "$__atty_doctor_fail_count" -eq 0 ]; then
    \\    printf '\033[32mall checks passed.\033[0m if `Alt+S` still fails, the OSC 133 gate error includes a \033[1mbytes=N dispatches=M\033[0m diagnostic — `dispatches>0` means atty IS seeing markers; `dispatches=0` means the shell never emitted any (even though the hooks look wired — try `set | grep PROMPT`)\n'
    \\else
    \\    printf '\033[31m%d check(s) failed.\033[0m fix the items above (most often: re-run the init eval AFTER your .bashrc / prompt manager has finished setting up PROMPT_COMMAND)\n' "$__atty_doctor_fail_count"
    \\fi
    \\unset -f __atty_doctor_ok __atty_doctor_fail __atty_doctor_warn __atty_doctor_check 2>/dev/null
    \\unset __atty_doctor_pass __atty_doctor_fail_count \
    \\      __atty_doctor_guard_bin __atty_doctor_guard_bin_label \
    \\      __atty_doctor_guard_unit __atty_doctor_guard_unit_sys \
    \\      __atty_doctor_guard_unit_user __atty_doctor_guard_mode \
    \\      __atty_doctor_guard_sock __atty_doctor_guard_features_rc \
    \\      __atty_doctor_guard_execstart __atty_doctor_guard_journal_cmd 2>/dev/null
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
