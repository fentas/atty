#!/usr/bin/env bash
# probe.sh — meta-test that verifies scenarios actually catch
# regressions. Inject a controlled break, run the relevant scenario,
# confirm it FAILS. Revert. Run again, confirm it PASSES.
#
# Why: a test that doesn't fail on a real bug is worse than no test
# at all. This script gives a one-shot answer to "do my scenarios
# detect what they claim to detect?"
#
# Usage:
#   tests/integration/probe.sh
#
# Exits non-zero if any probe doesn't behave as expected (regression
# wasn't caught OR clean state failed).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS=()

probe() {
    local label="$1"
    local injection_file="$2"
    local injection_apply="$3"
    local scenario="$4"

    echo "=== probe: $label ==="
    # 1. Confirm clean state passes.
    echo "  clean: running $scenario …"
    if ! bash "$SCRIPT_DIR/scenarios/$scenario.sh" >/dev/null 2>&1; then
        RESULTS+=("BAD-PROBE: $label — scenario fails BEFORE injection (probe invalid)")
        return
    fi

    # 2. Inject break with explicit revert-on-failure. Without this,
    # a bad sed/python pattern would leave `.probe-bak` AND a
    # half-modified source in tree — the next probe's `cp` then
    # overwrites the backup with the corrupted file. We don't use an
    # `ERR` trap here: `if ! eval ...` disables Bash's `set -e`
    # behaviour for the wrapped command, so we check the exit status
    # explicitly and revert on the early-exit branch.
    echo "  inject: $injection_apply"
    cp "$injection_file" "$injection_file.probe-bak"
    if ! eval "$injection_apply"; then
        mv "$injection_file.probe-bak" "$injection_file"
        RESULTS+=("BAD-PROBE: $label — injection step failed")
        return
    fi

    # 3. Rebuild affected component. `touch` so cargo doesn't no-op
    # when the file's contents revert to a known-cached state (binary
    # would then be from the OLD injected build).
    touch "$injection_file"
    if [[ "$injection_file" == *"atty-guard"* ]]; then
        (cd "$REPO_ROOT/atty-guard" && cargo build --release --features tier2-onnx,osv-live,atoms-fetch --quiet) || true
    else
        (cd "$REPO_ROOT" && zig build -Doptimize=ReleaseSafe >/dev/null 2>&1) || true
    fi

    # 4. Run scenario — expect FAIL.
    echo "  injected: running $scenario …"
    if bash "$SCRIPT_DIR/scenarios/$scenario.sh" >/dev/null 2>&1; then
        RESULTS+=("DID-NOT-CATCH: $label — scenario passed despite injected regression")
    else
        RESULTS+=("OK: $label")
    fi

    # 5. Revert + rebuild (always — even if step 4 errored).
    mv "$injection_file.probe-bak" "$injection_file"
    touch "$injection_file"
    if [[ "$injection_file" == *"atty-guard"* ]]; then
        (cd "$REPO_ROOT/atty-guard" && cargo build --release --features tier2-onnx,osv-live,atoms-fetch --quiet) || true
    else
        (cd "$REPO_ROOT" && zig build -Doptimize=ReleaseSafe >/dev/null 2>&1) || true
    fi
}

# Probe 1: invert the npm flagged-list check. tier1_npm_flagged
# expects `npm install event-stream` to Warn — if we comment out
# the flagged-package emission, it'll stay Safe and the scenario
# should fail.
probe "tier1_npm_flagged catches broken flagged-list check" \
    "$REPO_ROOT/atty-guard/src/classifier.rs" \
    'sed -i.tmp "s/self.flagged_npm_packages.contains(&name)/false/" "$REPO_ROOT/atty-guard/src/classifier.rs" && rm "$REPO_ROOT/atty-guard/src/classifier.rs.tmp"' \
    "tier1_npm_flagged"

# Probe 2: replace the GTFOBins `extract_gtfobins_atoms` function with
# a no-op early-return. atom_fetcher_gtfobins should then see 0 atoms
# and fail.
probe "atom_fetcher_gtfobins catches parser regression" \
    "$REPO_ROOT/atty-guard/src/atom_fetcher.rs" \
    'python3 -c "
import re
path = \"$REPO_ROOT/atty-guard/src/atom_fetcher.rs\"
src = open(path).read()
# Inject early-return at the top of extract_gtfobins_atoms — a real
# regression that the live-pull scenario should catch.
new = src.replace(
    \"fn extract_gtfobins_atoms(content: &str, atoms: &mut BTreeSet<String>) {\",
    \"fn extract_gtfobins_atoms(content: &str, atoms: &mut BTreeSet<String>) { return;\",
    1,
)
assert new != src, \"probe injection did not match\"
open(path, \"w\").write(new)
"' \
    "atom_fetcher_gtfobins"

# Probe 3: disable the V2-J-2 escalation entirely. v2j2_autoblock
# expects Block; with escalation off, we'd see Warn.
probe "v2j2_autoblock_threshold catches escalation regression" \
    "$REPO_ROOT/atty-guard/src/classifier.rs" \
    'sed -i.tmp "s/Some(t) if hits.len() >= 2 && conf >= t/Some(_) if false/" "$REPO_ROOT/atty-guard/src/classifier.rs" && rm "$REPO_ROOT/atty-guard/src/classifier.rs.tmp"' \
    "v2j2_autoblock_threshold"

echo
echo "=== probe summary ==="
FAILED=0
for r in "${RESULTS[@]}"; do
    echo "$r"
    case "$r" in
        OK:*) ;;
        *) FAILED=$((FAILED + 1)) ;;
    esac
done
exit $FAILED
