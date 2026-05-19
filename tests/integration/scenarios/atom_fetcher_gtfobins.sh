#!/usr/bin/env bash
# V2-I atom fetcher: pulls GTFOBins atoms from
# https://gtfobins.github.io/'s tarball, parses the markdown front
# matter + code blocks, emits a `flagged_atoms.txt`-compatible file.
# Requires outbound HTTPS to codeload.github.com.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_cmd curl

# Pre-flight: can we even reach github? Skip if no network.
if ! curl -sS --max-time 5 -o /dev/null -I https://codeload.github.com/; then
    skip "no network to codeload.github.com"
    exit 0
fi

build_guard

# Use an isolated XDG_DATA_HOME so the production atoms file doesn't
# get clobbered by the test.
export XDG_DATA_HOME="$(mktemp -d -t atty-guard-xdg.XXXXXX)"
trap 'rm -rf "$XDG_DATA_HOME"' EXIT
OUT_FILE="$XDG_DATA_HOME/atty-guard/flagged_atoms.txt"

# `--update-atoms-now` is a one-shot subcommand — fetches, writes,
# exits. Doesn't start the UDS server. Source filter restricts to
# GTFOBins only.
if ! "$GUARD_BIN" --update-atoms-now --atoms-sources gtfobins 2>&1 | tee /tmp/atoms-update.log >&2; then
    fail "--update-atoms-now gtfobins failed (see /tmp/atoms-update.log)"
fi

if [ ! -f "$OUT_FILE" ]; then
    fail "atoms file not written at $OUT_FILE"
fi

# A populated atoms file has many lines; sanity-check 50+ entries
# (GTFOBins ships ~200 binaries, each contributing at least one).
LINE_COUNT=$(grep -cv '^#\|^$' "$OUT_FILE" || true)
if [ "$LINE_COUNT" -lt 50 ]; then
    fail "expected ≥ 50 atoms from GTFOBins, got $LINE_COUNT"
fi

# Spot-check a known binary that GTFOBins documents (`nc` is canonical).
if ! grep -q "^nc " "$OUT_FILE" && ! grep -q " nc " "$OUT_FILE"; then
    fail "expected nc-related atom from GTFOBins, none found"
fi

pass "atom-fetcher GTFOBins source: $LINE_COUNT atoms pulled"
