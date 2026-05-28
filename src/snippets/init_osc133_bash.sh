
# OSC 133 prompt markers — tell atty (and Ghostty / VS Code /
# iTerm / …) where prompts start (A), where user input begins
# (B), and where commands finish (D + exit code). atty uses
# A/B to capture the user's typed line for accurate history
# recall; without these it falls back to keystroke tracking,
# which loses fidelity on completion and multi-line edits.
#
# `__atty_osc133_wrap_ps1` is run from PROMPT_COMMAND so it
# re-applies the `;A` / `;B` wrap on every cycle. Prompt
# managers like Starship overwrite PS1 inside their own
# precmd; a one-shot `PS1=…;A…;B…` at init time gets blown
# away on the first redraw. Idempotent: if the wrap is
# already on PS1 we return, so users without a prompt
# manager don't pay re-wrapping cost.
__atty_osc133_d() {
    # PRESERVE the user's command exit code through the hook —
    # other PROMPT_COMMAND consumers (direnv, starship, zoxide,
    # …) inspect `$?` to render "last command status" /
    # conditional output. Without the explicit `return`,
    # `printf`'s exit code (0 unless the write failed) would
    # shadow the real exit code and every command would look
    # successful to downstream hooks.
    local __code=$?
    printf '\033]133;D;%s\007' "$__code"
    return "$__code"
}
__atty_osc133_wrap_ps1() {
    # Skip ONLY when both `;A` and `;B` are already in PS1
    # (in order) — that's atty's wrap signature. A partial
    # integration that injected `;A` alone (Ghostty's
    # `shell-integration-features = osc-133` does this for
    # some shells) would otherwise short-circuit us and atty
    # would never get its `;B` input-region marker, which is
    # what the OSC 133 tracker actually keys on for accurate
    # input capture.
    case "$PS1" in
        *$'\033]133;A\007'*$'\033]133;B\007'*) return ;;
    esac
    PS1=$'\\[\033]133;A\007\\]'"${PS1}"$'\\[\033]133;B\007\\]'
}
# bash 5.1+ supports PROMPT_COMMAND as an array. Prompt
# managers (starship, oh-my-posh, p10k…) typically switch it to
# array form on 5.1+ AND replace PS1 inside their own precmd.
# For atty's wrap to survive, it MUST run AFTER theirs — which
# means appending it as a separate array element rather than
# semicolon-chaining inside whatever element[0] happens to be.
# String form (bash <5.1, or 5.1+ where no manager has switched
# PROMPT_COMMAND to array yet) keeps the original semicolon
# concat — correct in that mode.
# `;C` (command-start marker) is emitted from a DEBUG trap —
# bash has no native preexec hook, so we synthesise one. The
# trap fires for every simple command bash executes; we gate
# emission so only the FIRST simple command of each logical
# user-typed command produces `;C`. Without this gate ;C would
# fire many times per prompt cycle (every function call in
# PROMPT_COMMAND, every pipeline component, every subshell).
#
# The flag is reset at the END of PROMPT_COMMAND so the next
# user command re-arms emission. Existing DEBUG traps
# (starship's `_starship_set_return`, atuin's
# `__atuin_preexec`, etc.) are chained — atty's trap APPENDS
# its body rather than overwriting, so prompt-manager exit-
# code capture and history-tracking hooks keep firing.
__atty_osc133_c_emitted=1
__atty_osc133_preexec() {
    # Skip inside readline completion subshells (bash sets
    # COMP_LINE while running completion functions). Without
    # this guard ;C fires during Tab-completion expansion,
    # which the proxy then sees as "user just ran a command"
    # — confuses the OSC 133 state machine.
    [[ -n "${COMP_LINE-}" ]] && return
    (( __atty_osc133_c_emitted )) && return
    __atty_osc133_c_emitted=1
    printf '\033]133;C\007'
}
__atty_osc133_reset_c() { __atty_osc133_c_emitted=0; }
__atty_osc133_setup_debug_trap() {
    # Idempotency: skip if atty's preexec is already chained.
    case "$(trap -p DEBUG 2>/dev/null)" in
        *__atty_osc133_preexec*) return ;;
    esac
    local existing
    existing="$(trap -p DEBUG 2>/dev/null)"
    if [[ -z "$existing" ]]; then
        trap '__atty_osc133_preexec' DEBUG
    else
        # `trap -p DEBUG` outputs `trap -- 'BODY' DEBUG` —
        # strip the wrapping to extract BODY for chaining.
        # Single-quote embedded in BODY would break this
        # parse, but no shipped tool's DEBUG trap body
        # contains quoted bodies in practice (starship,
        # atuin, bash-preexec all use plain function calls).
        existing="${existing#trap -- \'}"
        existing="${existing%\' DEBUG}"
        trap "${existing}; __atty_osc133_preexec" DEBUG
    fi
}
if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
    PROMPT_COMMAND=("__atty_osc133_d" "${PROMPT_COMMAND[@]}" "__atty_osc133_wrap_ps1" "__atty_osc133_reset_c")
else
    PROMPT_COMMAND="__atty_osc133_d${PROMPT_COMMAND:+;}${PROMPT_COMMAND:-};__atty_osc133_wrap_ps1;__atty_osc133_reset_c"
fi
__atty_osc133_setup_debug_trap
__atty_osc133_wrap_ps1
