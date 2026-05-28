
# OSC 133 prompt markers — see `atty init bash` or `atty init zsh`
# for shell-specific hooks. atty falls back to keystroke
# tracking when these aren't emitted.
if [ -n "${BASH_VERSION:-}" ]; then
    __atty_osc133_d() { local __code=$?; printf '\033]133;D;%s\007' "$__code"; }
    PROMPT_COMMAND="__atty_osc133_d${PROMPT_COMMAND:+;}${PROMPT_COMMAND:-}"
    PS1=$'\\[\033]133;A\007\\]'"${PS1}"$'\\[\033]133;B\007\\]'
elif [ -n "${ZSH_VERSION:-}" ]; then
    __atty_osc133_precmd() {
        local __code=$?
        printf '\e]133;D;%s\a' "$__code"
        printf '\e]133;A\a'
    }
    __atty_osc133_preexec() { printf '\e]133;C\a'; }
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd __atty_osc133_precmd
    add-zsh-hook preexec __atty_osc133_preexec
    PS1+=$'%{\e]133;B\a%}'
fi
