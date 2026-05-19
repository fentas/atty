#!/usr/bin/env bash
# V2-I-2 atom fetcher: LOLBAS Windows-binary corpus. Pulls + parses
# the LOLBAS-Project `yml/OSBinaries/` tree, extracts `Command` strings
# from each binary's `Commands:` list. Windows-targeted atoms but useful
# on Linux when WSL / cross-platform tooling shows up.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_cmd curl
if ! curl -sS --max-time 5 -o /dev/null -I https://codeload.github.com/; then
    skip "no network to codeload.github.com"
    exit 0
fi

build_guard

export XDG_DATA_HOME="$(mktemp -d -t atty-guard-xdg.XXXXXX)"
trap 'rm -rf "$XDG_DATA_HOME"' EXIT
OUT_FILE="$XDG_DATA_HOME/atty-guard/flagged_atoms.txt"

if ! "$GUARD_BIN" --update-atoms-now --atoms-sources lolbas 2>&1 | tee /tmp/atoms-lolbas.log >&2; then
    fail "--update-atoms-now lolbas failed (see /tmp/atoms-lolbas.log)"
fi
[ -f "$OUT_FILE" ] || fail "atoms file not written"

LINE_COUNT=$(grep -cv '^#\|^$' "$OUT_FILE" || true)
# LOLBAS lists 150+ Windows binaries, each with multiple commands.
if [ "$LINE_COUNT" -lt 30 ]; then
    fail "expected ≥ 30 atoms from LOLBAS, got $LINE_COUNT"
fi

pass "atom-fetcher LOLBAS source: $LINE_COUNT atoms pulled"
