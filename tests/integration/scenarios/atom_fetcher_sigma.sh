#!/usr/bin/env bash
# V2-I-2 atom fetcher: SigmaHQ Linux rule corpus. Pulls + parses the
# Sigma `rules-linux/` tree, extracts process_creation `CommandLine`
# strings as atoms. Requires outbound HTTPS to codeload.github.com.

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

if ! "$GUARD_BIN" --update-atoms-now --atoms-sources sigma 2>&1 | tee /tmp/atoms-sigma.log >&2; then
    fail "--update-atoms-now sigma failed (see /tmp/atoms-sigma.log)"
fi
[ -f "$OUT_FILE" ] || fail "atoms file not written"

LINE_COUNT=$(grep -cv '^#\|^$' "$OUT_FILE" || true)
# Sigma's linux rules ship hundreds of rules; expect ≥ 30 atoms.
if [ "$LINE_COUNT" -lt 30 ]; then
    fail "expected ≥ 30 atoms from Sigma, got $LINE_COUNT"
fi

pass "atom-fetcher Sigma source: $LINE_COUNT atoms pulled"
