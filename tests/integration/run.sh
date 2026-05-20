#!/usr/bin/env bash
# Top-level runner for tests/integration/.
#
# Usage:
#   tests/integration/run.sh quick     # scenarios with no external deps
#   tests/integration/run.sh full      # everything (skips when deps absent)
#   tests/integration/run.sh scenario <name>
#                                      # run one scenario by stem
#   tests/integration/run.sh list      # print scenario names
#
# Output: each scenario emits exactly one of PASS:/FAIL:/SKIP: + a
# message; the runner aggregates a summary at the end. Exits non-zero
# iff any scenario emitted FAIL.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIOS_DIR="$SCRIPT_DIR/scenarios"

# Quick = network-free, no models. Anything not in this list runs
# only under `full` (and may skip if deps absent).
QUICK_SCENARIOS=(
    tier1_curl_pipe_sh
    tier1_npm_flagged
    tier1_bash_c_base64
    tier1_atom_matcher
    tier2_stub_passes_through
    tier2_heuristic_proc_subst
    v2j_accumulator_3_atoms
    v2j_accumulator_slm_plus_atom
    v2j2_autoblock_threshold
    v2j2_single_hit_stays_warn
    v2j2_range_guard
    exploit_copy_fail_shapes
    exploit_shai_hulud_shapes
)

FULL_EXTRA_SCENARIOS=(
    tier2_onnx_bert
    llm_ollama_dialog_roundtrip
    atom_fetcher_gtfobins
    atom_fetcher_sigma
    atom_fetcher_lolbas
    atty_warn_arms_banner
    atty_block_refuses_outright
    atty_trust_cache_shortcircuit
)

usage() {
    sed -n '2,15p' "$0" | sed 's/^# //; s/^#//'
}

list_scenarios() {
    for s in "${QUICK_SCENARIOS[@]}"; do echo "$s  (quick)"; done
    for s in "${FULL_EXTRA_SCENARIOS[@]}"; do echo "$s  (full)"; done
}

run_one() {
    local stem="$1"
    local path="$SCENARIOS_DIR/$stem.sh"
    if [ ! -f "$path" ]; then
        printf "FAIL: %s — scenario script not found at %s\n" "$stem" "$path"
        return 2
    fi
    local out; out=$(bash "$path" 2>&1) || true
    # The scenario emits one line of PASS/FAIL/SKIP per invocation;
    # surface it as-is so the runner stays a single-line filter.
    local status_line; status_line=$(echo "$out" | grep -E "^(PASS|FAIL|SKIP):" | tail -1)
    if [ -z "$status_line" ]; then
        # Scenario didn't follow the convention — treat as failure
        # and dump output for forensics.
        printf "FAIL: %s — scenario produced no PASS/FAIL/SKIP line\n" "$stem"
        echo "$out" | sed 's/^/    /'
        return 1
    fi
    # Re-emit only the status line, prefixed with the scenario stem.
    local kind="${status_line%%:*}"
    local msg="${status_line#*: }"
    printf "%s: %s — %s\n" "$kind" "$stem" "$msg"
    [ "$kind" = "FAIL" ] && {
        # On failure, dump the captured output indented for forensics.
        echo "$out" | sed 's/^/    /'
        return 1
    }
    return 0
}

case "${1:-help}" in
    quick)
        echo "== running ${#QUICK_SCENARIOS[@]} quick scenarios =="
        FAILED=0
        for s in "${QUICK_SCENARIOS[@]}"; do
            run_one "$s" || FAILED=$((FAILED + 1))
        done
        echo "== quick: ${FAILED} failure(s) =="
        exit $FAILED
        ;;
    full)
        echo "== running ${#QUICK_SCENARIOS[@]} quick + ${#FULL_EXTRA_SCENARIOS[@]} extra scenarios =="
        FAILED=0
        for s in "${QUICK_SCENARIOS[@]}" "${FULL_EXTRA_SCENARIOS[@]}"; do
            run_one "$s" || FAILED=$((FAILED + 1))
        done
        echo "== full: ${FAILED} failure(s) =="
        exit $FAILED
        ;;
    scenario)
        [ -n "${2:-}" ] || { echo "usage: run.sh scenario <name>" >&2; exit 2; }
        run_one "$2"
        ;;
    list)
        list_scenarios
        ;;
    *)
        usage
        ;;
esac
