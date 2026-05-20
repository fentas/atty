#!/usr/bin/env bash
# atty-guard installer — system-daemon mode.
#
# Installs the binary to /usr/local/bin, creates the dedicated `atty`
# user/group, installs the systemd unit to /etc/systemd/system/, and
# enables it. Requires root (re-execs via sudo if not already root).
#
# WHY system daemon instead of systemd-user: atom + URL trust state
# influences detection. A user-writable trust file is a DOS vector
# (process running as $USER could poison atoms with common commands
# and force atty-guard to be disabled). atty:atty-owned state under
# /var/lib/atty-guard/ keeps mutations outside the user's write
# reach. The mutation API (planned: `sudo atty-guard atoms add/...`
# CLI subcommands) lands in PR #141; PR #140 only sets up the
# foundation — daemon under the dedicated user, state dirs in place.
#
# Build first:
#   cd atty-guard && cargo build --release
#
# Install:
#   sudo ./contrib/install.sh
#   (or:  make install-guard  — wraps this)
#
# To remove:
#   sudo systemctl disable --now atty-guard
#   sudo rm -f /usr/local/bin/atty-guard /etc/systemd/system/atty-guard.service
#   sudo rm -rf /var/lib/atty-guard
#   sudo userdel atty   # if you also want to remove the user
#
# Users who want to talk to the daemon must be in the `atty` group:
#   sudo usermod -aG atty $USER
#   (re-login for the group change to take effect)

set -euo pipefail

# Parse args (before sudo re-exec so the flag forwards through).
WITH_EBPF=0
WITHOUT_EBPF=0
for arg in "$@"; do
    case "$arg" in
        --with-ebpf)
            WITH_EBPF=1
            ;;
        --without-ebpf)
            WITHOUT_EBPF=1
            ;;
        --help|-h)
            sed -n '2,32p' "$0" | sed 's/^# \?//'
            echo
            echo "Flags:"
            echo "  --with-ebpf      Install the eBPF systemd drop-in (CAP_BPF +"
            echo "                   SystemCallFilter widening + --enable-ebpf on"
            echo "                   ExecStart). Requires the binary to be built"
            echo "                   with --features ebpf (verified via"
            echo "                   --print-features post-install)."
            echo "  --without-ebpf   Explicitly remove the eBPF drop-in if present."
            echo "                   Use when downgrading from an ebpf install:"
            echo "                   without this flag a plain re-install leaves"
            echo "                   the existing drop-in in place (warn-only)."
            exit 0
            ;;
        *)
            echo "error: unknown flag: $arg (try --help)" >&2
            exit 1
            ;;
    esac
done

if [[ $WITH_EBPF -eq 1 && $WITHOUT_EBPF -eq 1 ]]; then
    echo "error: --with-ebpf and --without-ebpf are mutually exclusive" >&2
    exit 1
fi

# Re-exec under sudo if not already root. This mirrors the pattern
# in other system installers (e.g. rustup, ohmyzsh) — keep the
# user's PWD and SHELL invocation intact across the elevation.
if [[ $EUID -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "error: this installer requires root. install sudo or run as root." >&2
        exit 1
    fi
    # Drop the caller's env (no `-E`). The default sudo `env_reset`
    # behavior is what we want — passing `-E` would leak LD_PRELOAD /
    # LD_LIBRARY_PATH / similar from the unprivileged caller into the
    # root-EUID re-exec, an obvious privesc surface. This installer
    # reads no caller env (REPO_ROOT is derived from $0 and all other
    # paths are hardcoded), so env_reset is safe.
    exec sudo -- bash "$0" "$@"
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_SRC="$REPO_ROOT/target/release/atty-guard"

# System install paths. Hardcoded — system-daemon installs don't
# honour PREFIX because the systemd unit references absolute paths
# and the dedicated user's home base is a known FHS location.
BIN_DST="/usr/local/bin/atty-guard"
UNIT_SRC="$REPO_ROOT/contrib/atty-guard.service"
UNIT_DST="/etc/systemd/system/atty-guard.service"
STATE_DIR="/var/lib/atty-guard"

if [[ ! -x "$BIN_SRC" ]]; then
    echo "error: $BIN_SRC not found." >&2
    echo "       run 'cd atty-guard && cargo build --release' first." >&2
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    echo "error: systemctl not on \$PATH — this installer assumes systemd." >&2
    exit 1
fi

# Create atty system user + group (idempotent — getent is a no-op if
# they already exist). System user means UID < 1000, no home dir, no
# login shell — the standard dedicated-daemon pattern (postgres,
# postfix, etc.).
if ! getent group atty >/dev/null 2>&1; then
    groupadd --system atty
    echo "created system group 'atty'"
fi
if ! getent passwd atty >/dev/null 2>&1; then
    useradd --system --gid atty --no-create-home \
        --home-dir /nonexistent --shell /usr/sbin/nologin \
        --comment "atty-guard sidecar daemon" atty
    echo "created system user 'atty'"
fi

# Atomic binary install.
install -o root -g root -m 0755 "$BIN_SRC" "$BIN_DST.tmp.$$"
mv -f "$BIN_DST.tmp.$$" "$BIN_DST"
echo "installed $BIN_DST"

# State directory — atom files + URL decisions live here. atty:atty
# owned, mode 0750 (atty user can read/write, atty group can read,
# others nothing). The daemon refuses to load atom files that don't
# match this ownership at startup.
install -d -o atty -g atty -m 0750 "$STATE_DIR"
echo "ensured $STATE_DIR (atty:atty 0750)"

# Service unit.
install -o root -g root -m 0644 "$UNIT_SRC" "$UNIT_DST"
echo "installed $UNIT_DST"

# eBPF drop-in (--with-ebpf only). Lives at
# /etc/systemd/system/atty-guard.service.d/ebpf.conf so the
# baseline unit stays vanilla — operators can drop the override
# back to ExecStart-only by `rm` of the drop-in, no edit needed.
EBPF_DROPIN_DIR="/etc/systemd/system/atty-guard.service.d"
EBPF_DROPIN_FILE="$EBPF_DROPIN_DIR/ebpf.conf"
if [[ $WITH_EBPF -eq 1 ]]; then
    # Verify the binary was built with the feature. The
    # --print-features probe (added in #145) emits one feature per
    # line. Distinguish two failure modes that both produce a
    # non-zero grep:
    #   A) binary is too old to support --print-features at all
    #      (the flag was added in #145, mid-2026). Operator needs
    #      to upgrade atty-guard before we can certify the feature.
    #   B) binary supports the flag but `ebpf` isn't in its output
    #      — feature wasn't built in. Operator needs the right
    #      GUARD_FEATURES on their rebuild.
    # Probe in two steps so the error message points at the right
    # remedy.
    if ! "$BIN_DST" --print-features >/dev/null 2>&1; then
        echo "error: --with-ebpf passed but $BIN_DST does not support --print-features." >&2
        echo "       upgrade your atty-guard install — the probe landed in issue #145." >&2
        exit 1
    fi
    if ! "$BIN_DST" --print-features 2>/dev/null | grep -qx ebpf; then
        echo "error: --with-ebpf passed but binary lacks the ebpf cargo feature." >&2
        echo "       rebuild with:" >&2
        echo "         cd atty-guard && cargo build --release --features ebpf" >&2
        echo "       (or via the Makefile: make build-guard GUARD_FEATURES=...,ebpf)" >&2
        exit 1
    fi
    install -d -o root -g root -m 0755 "$EBPF_DROPIN_DIR"
    # Heredoc uses unquoted EOF so $BIN_DST expands — keeps the
    # ExecStart path in sync with the actual install location (the
    # installer hardcodes /usr/local/bin today but might honour a
    # PREFIX in the future; the drop-in shouldn't bake the literal).
    # No other variables need expansion; backslash-escape any
    # accidental shell metachars inside the body to keep them
    # literal.
    cat > "$EBPF_DROPIN_FILE.tmp.$$" <<EOF
# atty-guard eBPF drop-in. Generated by \`install.sh --with-ebpf\`.
# Lifts the baseline unit's sandbox restrictions enough to load
# BPF programs (LSM hook + execve tracepoint + AF_ALG tracepoint
# — see atty-guard/ebpf/README.md). Remove this file to revert
# to the no-eBPF V2-A behaviour (in-memory threat map only).
[Service]
# CAP_BPF gates BPF_PROG_LOAD + BPF_MAP_CREATE; CAP_PERFMON gates
# perf_event_open used by tracepoint attach. Linux ≥ 5.8 split
# these out of CAP_SYS_ADMIN so daemons don't need the everything-
# capability for a narrow BPF need.
AmbientCapabilities=CAP_BPF CAP_PERFMON

# The baseline \`SystemCallFilter=@system-service\` excludes bpf()
# and perf_event_open() (both live in @privileged); widening the
# allowlist with the two specific syscalls keeps the rest of the
# seccomp profile intact.
SystemCallFilter=bpf perf_event_open

# Default unit has RestrictNamespaces=yes which blocks BPF
# map types that need namespace access (cgroup maps in
# particular). Clearing is wider than strictly needed but matches
# the minimal viable config; tighten later if BPF_MAP_TYPE usage
# narrows.
RestrictNamespaces=

# Re-emit ExecStart with --enable-ebpf so the daemon actually
# attaches the programs at startup (the flag is on the CLI
# unconditionally, but without it the loader is skipped — see
# main.rs's enable_ebpf gate).
ExecStart=
ExecStart=$BIN_DST --enable-ebpf
EOF
    mv -f "$EBPF_DROPIN_FILE.tmp.$$" "$EBPF_DROPIN_FILE"
    chmod 0644 "$EBPF_DROPIN_FILE"
    echo "installed $EBPF_DROPIN_FILE"
elif [[ $WITHOUT_EBPF -eq 1 ]]; then
    if [[ -f "$EBPF_DROPIN_FILE" ]]; then
        rm -f "$EBPF_DROPIN_FILE"
        echo "removed $EBPF_DROPIN_FILE (--without-ebpf)"
        # Also try the parent dir — `rmdir` is a no-op if other
        # drop-ins live there (e.g. an operator's custom override),
        # so this is safe.
        rmdir "$EBPF_DROPIN_DIR" 2>/dev/null || true
    else
        echo "note: no eBPF drop-in at $EBPF_DROPIN_FILE — nothing to remove."
    fi
elif [[ -f "$EBPF_DROPIN_FILE" ]]; then
    # Operator previously ran --with-ebpf, now re-running plain.
    # Leave the drop-in alone but warn — explicit removal via
    # --without-ebpf is the documented path.
    echo "note: existing eBPF drop-in at $EBPF_DROPIN_FILE left in place."
    echo "      pass --with-ebpf to re-confirm, --without-ebpf to remove."
fi

systemctl daemon-reload
systemctl enable --now atty-guard.service
echo
systemctl --no-pager --lines=5 status atty-guard.service || true
echo
echo "atty-guard is up. To let your user account talk to the daemon:"
echo
echo "  sudo usermod -aG atty \$USER"
echo "  # log out + back in (or 'newgrp atty' for a single shell)"
echo
echo "Then set 'daemon_socket_path' in src/config.zig:"
echo
echo "  .daemon_socket_path = \"/run/atty-guard/atty-guard.sock\","
echo
echo "Rebuild atty with the new socket path (make build-atty)."
