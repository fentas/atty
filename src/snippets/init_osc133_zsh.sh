
# OSC 133 prompt markers — tell atty (and Ghostty / VS Code /
# iTerm / …) where prompts start (A), where user input begins
# (B), where commands run (C), and where they finish (D + exit
# code). atty uses A/B to capture the user's typed line for
# accurate history recall; without these it falls back to
# keystroke tracking, which loses fidelity on completion and
# multi-line edits.
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
