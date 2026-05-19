#!/usr/bin/env bash
# atty-guard installer — drops the daemon binary in $PREFIX/bin (default
# ~/.local/bin) and enables the systemd-user unit. Idempotent;
# safe to re-run.
#
# Build first:
#   cd atty-guard && cargo build --release
#
# Then:
#   ./contrib/install.sh
#
# To install under a non-default prefix (matches the top-level Makefile's
# `PREFIX` variable):
#   PREFIX=/opt/foo ./contrib/install.sh
#
# To remove:
#   systemctl --user disable --now atty-guard
#   rm -f "$PREFIX/bin/atty-guard" "$XDG_CONFIG_HOME/systemd/user/atty-guard.service"

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_SRC="$REPO_ROOT/target/release/atty-guard"
# Honour PREFIX (matches the top-level Makefile convention) so
# `make install PREFIX=/opt/foo` lands BOTH atty and atty-guard under
# the same root. Default keeps the prior `${HOME}/.local` install dir.
PREFIX="${PREFIX:-${HOME}/.local}"
BIN_DST="${PREFIX}/bin/atty-guard"
UNIT_SRC="$REPO_ROOT/contrib/atty-guard.service"
UNIT_DST="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user/atty-guard.service"

if [[ ! -x "$BIN_SRC" ]]; then
    echo "error: $BIN_SRC not found." >&2
    echo "       run 'cd atty-guard && cargo build --release' first." >&2
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    echo "error: systemctl not on \$PATH — this installer assumes systemd." >&2
    echo "       you can still copy the binary to $BIN_DST and run it" >&2
    echo "       manually or via your init system of choice." >&2
    exit 1
fi

mkdir -p "$(dirname "$BIN_DST")" "$(dirname "$UNIT_DST")"

# Atomic install — write to a sibling tmp file then rename. Avoids
# the small window where a partially-written binary could be exec'd.
install -m 0755 "$BIN_SRC" "$BIN_DST.tmp.$$"
mv -f "$BIN_DST.tmp.$$" "$BIN_DST"
echo "installed $BIN_DST"

install -m 0644 "$UNIT_SRC" "$UNIT_DST"
echo "installed $UNIT_DST"

systemctl --user daemon-reload
systemctl --user enable --now atty-guard.service
echo
systemctl --user --no-pager --lines=5 status atty-guard.service || true
echo
echo "atty-guard is up. atty will find the socket automatically when"
echo "you set 'daemon_socket_path' in src/config.zig:"
echo
echo "  .daemon_socket_path = \"\${XDG_RUNTIME_DIR}/atty-guard.sock\","
echo
