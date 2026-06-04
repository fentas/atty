
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
# OSC 7 — cwd report so the outer terminal's "new window from this
# pane" keybind opens at the focused directory instead of `$HOME`.
# Ghostty / kitty / foot / WezTerm / VS Code each consume this.
# zsh inside atty doesn't get the outer terminal's shell-integration
# injection (ghostty injects into atty, not zsh), so emit it here.
__atty_osc7_cwd() { printf '\e]7;file://%s%s\a' "${HOST:-localhost}" "$PWD"; }
autoload -Uz add-zsh-hook
add-zsh-hook precmd __atty_osc133_precmd
add-zsh-hook precmd __atty_osc7_cwd
add-zsh-hook preexec __atty_osc133_preexec
PS1+=$'%{\e]133;B\a%}'
# Emit once at init so the outer terminal has the cwd before the
# user runs anything.
__atty_osc7_cwd
