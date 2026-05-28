# atty shell integration — drop this in your .bashrc / .zshrc:
#   eval "$(atty init bash)"
#
# Re-execs the current interactive shell under atty. atty
# injects ATTY=1 (and ATTY_PID / ATTY_VERSION) into the child
# shell's environment, so nested invocations — atty's own
# child, or any subshell it spawns — skip the exec and fall
# through to the OSC 133 setup. Only fires for TTY-attached
# interactive shells; scripts run unchanged.
if [ -z "${ATTY:-}" ] && [ -t 0 ] && [ -t 1 ]; then