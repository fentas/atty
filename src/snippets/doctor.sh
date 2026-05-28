# atty doctor — paste into your shell:  eval "$(atty doctor)"
__atty_doctor_ok()   { printf '  \033[32m✓\033[0m  %s\n' "$*"; }
__atty_doctor_fail() { printf '  \033[31m✗\033[0m  %s\n' "$*"; }
__atty_doctor_warn() { printf '  \033[33m!\033[0m  %s\n' "$*"; }
__atty_doctor_pass=0
__atty_doctor_fail_count=0
__atty_doctor_check() {
    if eval "$1"; then __atty_doctor_ok "$2"; __atty_doctor_pass=$((__atty_doctor_pass+1));
    else __atty_doctor_fail "$2 — $3"; __atty_doctor_fail_count=$((__atty_doctor_fail_count+1)); fi
}
printf '\033[1matty doctor\033[0m — OSC 133 integration\n\n'
__atty_doctor_check '[ -n "${ATTY:-}" ]' \
    'inside atty session ($ATTY set)' \
    'not running under atty — start a new shell with `atty bash`'
if [ -n "${BASH_VERSION:-}" ]; then
    __atty_doctor_ok "shell: bash $BASH_VERSION"
    # bash 5.1+ supports PROMPT_COMMAND-as-array. Mention this
    # in the doctor output (informational, not a failure — atty's
    # init handles both forms since the array-aware fix). If
    # `wrap_ps1` is at the END of the array we're good; if it's
    # embedded inside an earlier element (legacy/broken state
    # from a pre-fix install), later checks for `;A` / `;B` in
    # PS1 will surface the real failure.
    if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
        __atty_doctor_ok "PROMPT_COMMAND is an array (bash 5.1+, prompt manager active) — atty's init handles this"
    fi
    __atty_doctor_check 'declare -F __atty_osc133_d > /dev/null' \
        '__atty_osc133_d function defined' \
        'init eval was run OUTSIDE atty — its `exec atty bash` replaced your shell and discarded the function defs. Either add `eval "$(atty init bash)"` to your ~/.bashrc, or run it AGAIN now inside this session (ATTY=1 skips the exec, sets up OSC 133 in-place)'
    __atty_doctor_check 'declare -F __atty_osc133_wrap_ps1 > /dev/null' \
        '__atty_osc133_wrap_ps1 function defined' \
        'same as above — re-run `eval "$(atty init bash)"` inside this atty session'
    # `${PROMPT_COMMAND[*]}` flattens both string and array
    # forms — array elements get joined by the first char of
    # IFS (space by default), which is enough for substring
    # matching. Plain `${PROMPT_COMMAND:-}` would return only
    # the first array element and silently miss our wrap when
    # it lives as a separate (final) element.
    __atty_doctor_check 'case "${PROMPT_COMMAND[*]:-}" in *__atty_osc133_d*) true ;; *) false ;; esac' \
        'PROMPT_COMMAND wired to __atty_osc133_d' \
        'something overwrote PROMPT_COMMAND after the init eval (.bashrc / prompt manager?)'
    __atty_doctor_check 'case "${PROMPT_COMMAND[*]:-}" in *__atty_osc133_wrap_ps1*) true ;; *) false ;; esac' \
        'PROMPT_COMMAND wired to __atty_osc133_wrap_ps1' \
        'same as above — PROMPT_COMMAND was reassigned'
    __atty_doctor_check 'case "${PS1:-}" in *$(printf "\033]133;A\007")*) true ;; *) false ;; esac' \
        'PS1 contains `;A` prompt-start marker' \
        'wrap_ps1 never ran on the current prompt (try pressing Enter once)'
    __atty_doctor_check 'case "${PS1:-}" in *$(printf "\033]133;B\007")*) true ;; *) false ;; esac' \
        'PS1 contains `;B` input-region marker' \
        'same as above — wrap_ps1 not yet applied'
    __atty_doctor_check 'declare -F __atty_osc133_preexec > /dev/null' \
        '__atty_osc133_preexec function defined (emits `;C`)' \
        'init eval ran with an older atty binary that lacked the DEBUG-trap-based `;C` emitter. Re-run after upgrading atty — dialog/auto mode needs `;C` to advance past `.executing` state.'
    # Bash scopes DEBUG/RETURN traps PER-FUNCTION unless `set -T`
    # is active globally — inside `__atty_doctor_check` (which is
    # what runs `eval "$1"`), `trap -p DEBUG` returns the empty
    # function-local trap, never the user's shell-level one.
    # Capture the trap state HERE in the outer scope and pass it
    # into the check as a variable, so the case-match happens on
    # data instead of re-querying from inside a function frame.
    __atty_doctor_dbg_trap="$(trap -p DEBUG 2>/dev/null)"
    __atty_doctor_check 'case "$__atty_doctor_dbg_trap" in *__atty_osc133_preexec*) true ;; *) false ;; esac' \
        'DEBUG trap wired to __atty_osc133_preexec' \
        'something replaced the DEBUG trap after init (a later loaded plugin?) — dialog will stall in `.executing` until the trap is restored. Re-run `eval "$(atty init bash)"` AFTER all plugins finish setting up traps.'
elif [ -n "${ZSH_VERSION:-}" ]; then
    __atty_doctor_ok "shell: zsh $ZSH_VERSION"
    __atty_doctor_check 'typeset -f __atty_osc133_precmd > /dev/null' \
        '__atty_osc133_precmd function defined' \
        'did you run `eval "$(atty init zsh)"` yet?'
    __atty_doctor_check 'typeset -f __atty_osc133_preexec > /dev/null' \
        '__atty_osc133_preexec function defined' \
        'did you run `eval "$(atty init zsh)"` yet?'
    __atty_doctor_check '(( ${precmd_functions[(I)__atty_osc133_precmd]} ))' \
        'precmd hook installed' \
        'add-zsh-hook precmd never ran — re-run the eval'
    __atty_doctor_check '(( ${preexec_functions[(I)__atty_osc133_preexec]} ))' \
        'preexec hook installed' \
        'add-zsh-hook preexec never ran — re-run the eval'
else
    __atty_doctor_warn 'unknown shell — only bash and zsh are first-class. Press `Alt+A` for single-shot LLM, dialog/auto modes need OSC 133.'
fi

# atty-guard sidecar — security_guard's optional V2-* backend.
# Each check is non-fatal: a fresh atty install runs fine with
# the in-proc Tier-1 only (no daemon). The checks fire only
# when there's evidence the operator INTENDED to install the
# sidecar (system binary present OR system unit installed);
# otherwise the section is silent. The doctor knows about both
# the system-daemon install (post-#140 default) AND the legacy
# systemd-user install (pre-#140 — flagged with a one-line
# migration nudge).
__atty_doctor_guard_bin=""
if command -v atty-guard >/dev/null 2>&1; then
    __atty_doctor_guard_bin="$(command -v atty-guard)"
elif [ -x /usr/local/bin/atty-guard ]; then
    __atty_doctor_guard_bin="/usr/local/bin/atty-guard"
elif [ -x "$HOME/.local/bin/atty-guard" ]; then
    __atty_doctor_guard_bin="$HOME/.local/bin/atty-guard"
fi
__atty_doctor_guard_unit_sys=/etc/systemd/system/atty-guard.service
__atty_doctor_guard_unit_user="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/atty-guard.service"
__atty_doctor_guard_unit=""
__atty_doctor_guard_mode=""
if [ -f "$__atty_doctor_guard_unit_sys" ]; then
    __atty_doctor_guard_unit="$__atty_doctor_guard_unit_sys"
    __atty_doctor_guard_mode=system
elif [ -f "$__atty_doctor_guard_unit_user" ]; then
    __atty_doctor_guard_unit="$__atty_doctor_guard_unit_user"
    __atty_doctor_guard_mode=user
fi
if [ -n "$__atty_doctor_guard_bin" ] || [ -n "$__atty_doctor_guard_unit" ]; then
    printf '\n\033[1matty doctor\033[0m — atty-guard sidecar\n\n'
    if [ "$__atty_doctor_guard_mode" = "user" ]; then
        # Pre-#140 install. Still works for the bundled-corpus
        # path but doesn't have the dedicated `atty` user / file
        # ownership protections. Nudge to migrate but don't fail
        # the check.
        __atty_doctor_warn 'systemd-user install detected (pre-#140). Migrate to the system-daemon install by running `sudo make install-guard` from the atty source tree — moves atty-guard under a dedicated `atty` user with permission-checked atom files at /var/lib/atty-guard/.'
    fi
    if [ -n "$__atty_doctor_guard_bin" ]; then
        __atty_doctor_guard_bin_label="atty-guard binary present ($__atty_doctor_guard_bin)"
    else
        __atty_doctor_guard_bin_label="atty-guard binary present"
    fi
    __atty_doctor_check '[ -n "'"$__atty_doctor_guard_bin"'" ]' \
        "$__atty_doctor_guard_bin_label" \
        'install with `sudo make install-guard` (from the atty source tree) or download the binary from https://github.com/fentas/atty/releases'
    __atty_doctor_check '[ -f "'"$__atty_doctor_guard_unit_sys"'" ] || [ -f "'"$__atty_doctor_guard_unit_user"'" ]' \
        'atty-guard.service unit installed' \
        '`sudo make install-guard` writes the system unit to /etc/systemd/system/ and enables it'
    if command -v systemctl >/dev/null 2>&1; then
        if [ "$__atty_doctor_guard_mode" = "system" ]; then
            __atty_doctor_check 'systemctl is-active --quiet atty-guard.service 2>/dev/null' \
                'atty-guard.service is active' \
                'sudo systemctl start atty-guard.service (check `systemctl status atty-guard` for the actual reason if it refuses)'
        else
            __atty_doctor_check 'systemctl --user is-active --quiet atty-guard.service 2>/dev/null' \
                'atty-guard.service is active (systemd-user — legacy)' \
                'systemctl --user start atty-guard.service (and consider migrating to the system install per the warning above)'
        fi
    fi
    # Socket path differs by install mode. System daemon binds
    # /run/atty-guard/atty-guard.sock (atty:atty 0750 group-
    # readable). Legacy systemd-user binds under $XDG_RUNTIME_DIR
    # or /tmp/atty-guard-<uid>.sock.
    if [ "$__atty_doctor_guard_mode" = "system" ]; then
        __atty_doctor_guard_sock=/run/atty-guard/atty-guard.sock
    elif [ -n "${XDG_RUNTIME_DIR-}" ]; then
        __atty_doctor_guard_sock="$XDG_RUNTIME_DIR/atty-guard.sock"
    else
        __atty_doctor_guard_sock="/tmp/atty-guard-$(id -u).sock"
    fi
    __atty_doctor_check '[ -S "'"$__atty_doctor_guard_sock"'" ]' \
        "UDS socket reachable ($__atty_doctor_guard_sock)" \
        'service started but socket missing — likely a permission or path mismatch; the daemon prints the bind error to journald on startup'
    if [ "$__atty_doctor_guard_mode" = "system" ]; then
        # System-daemon mode requires the user to be in the
        # `atty` group to connect to the socket.
        if id -nG 2>/dev/null | grep -qw atty; then
            __atty_doctor_ok 'user is in `atty` group (can connect to the daemon socket)'
        else
            __atty_doctor_fail 'user not in `atty` group' 'sudo usermod -aG atty $USER; then log out + back in (or `newgrp atty` for a single shell)'
        fi
    fi
    # Atom corpus check intentionally NOT done here. atty-guard's
    # AtomMatcher reads its corpus via `include_str!` at compile
    # time — there is no runtime atom file the daemon loads
    # today. The optional `--update-atoms-now` writes to
    # $XDG_DATA_HOME but the daemon ignores that file. Checking
    # for it would either fail (file absent) for users on a
    # bundled-only install (the supported path), or pass (file
    # present) but mislead — the file's existence has no effect
    # on detection. Runtime atom loading is on the post-#139
    # roadmap; the doctor check returns when it's wired up.
    # eBPF feature detection — uses `atty-guard --print-features`
    # (post-issue-#145) which emits one Cargo feature per line.
    # This is the authoritative probe: each feature name comes
    # from a `#[cfg(feature = ...)]` block at compile time so the
    # output is exactly the set baked into the running binary.
    # Falls back to "unknown" for older binaries that don't
    # support the flag (pre-issue-#145 installs).
    if [ -n "$__atty_doctor_guard_bin" ]; then
        # Three-state eBPF check, in order:
        #   1. Binary doesn't support --print-features
        #      (pre-issue-#145 install). Surface as a warn,
        #      can't tell whether eBPF is compiled.
        #   2. Feature is compiled BUT the unit's ExecStart
        #      doesn't pass --enable-ebpf. Compiled but inert;
        #      point at `sudo make install-guard GUARD_FEATURES=ebpf`.
        #   3. Feature compiled + unit has --enable-ebpf.
        #      Then check journald for the "eBPF attached"
        #      line — green if found, warn (with the actual
        #      error line) if not.
        #
        # Pipes the `--print-features` output DIRECTLY into
        # grep — capturing into a shell var collapses newlines
        # to spaces, breaking `grep -qx` for multi-feature
        # builds.
        "$__atty_doctor_guard_bin" --print-features >/dev/null 2>&1
        __atty_doctor_guard_features_rc=$?
        if [ $__atty_doctor_guard_features_rc -ne 0 ]; then
            __atty_doctor_warn 'eBPF feature: cannot detect (atty-guard does not support --print-features — upgrade your atty-guard install for definitive feature reporting)'
        elif "$__atty_doctor_guard_bin" --print-features 2>/dev/null | grep -qx ebpf; then
            # Check whether the running unit was configured to
            # actually load the BPF programs. ExecStart must
            # carry `--enable-ebpf`; without it the daemon skips
            # the loader regardless of the feature being baked in.
            # Read from the live systemd state to honour any
            # drop-in (the ebpf.conf installed by `install.sh
            # --with-ebpf` lives at
            # /etc/systemd/system/atty-guard.service.d/).
            # `systemctl show` is mode-sensitive: legacy user
            # installs need `--user` or it queries the system bus
            # and returns nothing.
            if [ "$__atty_doctor_guard_mode" = "user" ]; then
                __atty_doctor_guard_execstart="$(systemctl --user show atty-guard.service -p ExecStart --value 2>/dev/null || true)"
                __atty_doctor_guard_journal_probe='journalctl --user -u atty-guard.service -b'
                __atty_doctor_guard_journal_hint="$__atty_doctor_guard_journal_probe"
            else
                __atty_doctor_guard_execstart="$(systemctl show atty-guard.service -p ExecStart --value 2>/dev/null || true)"
                # Probe WITHOUT sudo first. Many setups have the
                # operator in the `systemd-journal` group (or
                # equivalent) and root isn't needed to read
                # service logs. Falls through to a sudo-prefixed
                # HINT (not an execution) if the unprivileged
                # probe yields no journal entries — `eval
                # "$(atty doctor)"` should NEVER block on a sudo
                # password prompt mid-output.
                __atty_doctor_guard_journal_probe='journalctl -u atty-guard.service -b'
                __atty_doctor_guard_journal_hint='sudo journalctl -u atty-guard.service -b'
            fi
            if echo "$__atty_doctor_guard_execstart" | grep -q -- '--enable-ebpf'; then
                # Scope the journald scan to the current boot —
                # the "eBPF attached" line is emitted once per
                # daemon start, so a unit up >24h with no restart
                # would spuriously warn with a fixed time window.
                # `-b` is faster AND captures exactly the running
                # instance's log.
                if eval "$__atty_doctor_guard_journal_probe" 2>/dev/null | grep -q 'eBPF attached'; then
                    __atty_doctor_ok 'eBPF: compiled + ExecStart --enable-ebpf + journald shows "eBPF attached" this boot'
                else
                    __atty_doctor_warn "eBPF: compiled + ExecStart has --enable-ebpf BUT no 'eBPF attached' line visible to this user this boot. Run \`$__atty_doctor_guard_journal_hint | grep -i ebpf\` to see the actual reason (typical: kernel lacks BPF LSM, daemon lacks CAP_BPF, or the .bpf.o object isn't on the loader's search path). If you're not in the systemd-journal group, the sudo'd hint is the visible-to-you path."
                fi
            else
                __atty_doctor_warn 'eBPF: compiled in BUT ExecStart does NOT pass --enable-ebpf. The drop-in at /etc/systemd/system/atty-guard.service.d/ebpf.conf is missing — install via `sudo make install-guard GUARD_FEATURES=tier2-onnx,osv-live,atoms-fetch,ebpf`'
            fi
        else
            __atty_doctor_warn 'eBPF feature: NOT compiled in. Rebuild atty-guard with `make build-guard GUARD_FEATURES=...,ebpf` then `sudo make install-guard GUARD_FEATURES=...,ebpf` to wire the drop-in. Optional — V2-A in-memory threat-map is the fallback.'
        fi
    fi
fi
printf '\n'
if [ "$__atty_doctor_fail_count" -eq 0 ]; then
    printf '\033[32mall checks passed.\033[0m if `Alt+S` still fails, the OSC 133 gate error includes a \033[1mbytes=N dispatches=M\033[0m diagnostic — `dispatches>0` means atty IS seeing markers; `dispatches=0` means the shell never emitted any (even though the hooks look wired — try `set | grep PROMPT`)\n'
else
    printf '\033[31m%d check(s) failed.\033[0m fix the items above (most often: re-run the init eval AFTER your .bashrc / prompt manager has finished setting up PROMPT_COMMAND)\n' "$__atty_doctor_fail_count"
fi
unset -f __atty_doctor_ok __atty_doctor_fail __atty_doctor_warn __atty_doctor_check 2>/dev/null
unset __atty_doctor_pass __atty_doctor_fail_count \
      __atty_doctor_guard_bin __atty_doctor_guard_bin_label \
      __atty_doctor_guard_unit __atty_doctor_guard_unit_sys \
      __atty_doctor_guard_unit_user __atty_doctor_guard_mode \
      __atty_doctor_guard_sock __atty_doctor_guard_features_rc \
      __atty_doctor_guard_execstart __atty_doctor_guard_journal_probe \
      __atty_doctor_guard_journal_hint 2>/dev/null
