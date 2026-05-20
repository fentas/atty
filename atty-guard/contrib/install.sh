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
# /var/lib/atty-guard/ + mediated CLI keeps mutations behind sudo.
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

# Re-exec under sudo if not already root. This mirrors the pattern
# in other system installers (e.g. rustup, ohmyzsh) — keep the
# user's PWD and SHELL invocation intact across the elevation.
if [[ $EUID -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "error: this installer requires root. install sudo or run as root." >&2
        exit 1
    fi
    exec sudo -E bash "$0" "$@"
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
