#!/usr/bin/env bash
# LLM module: dialog mode round-trips through a real Ollama-served
# SLM. Sends a one-shot `#: <prompt>` via atty's stdin, waits for the
# LLM to return a command suggestion. Requires `ollama serve` reachable
# and `$ATTY_OLLAMA_MODEL` (default `qwen2.5-coder:1.5b`) pulled.
#
# This is the BIGGEST test we run — it exercises the full pipeline:
#   PTY proxy → onInput → AI mode detection → worker HTTP request →
#   Ollama generation → response parse → command staged on prompt.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

BUILD_LOG=$(mktemp -t atty-build.XXXXXX.log)

OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
OLLAMA_MODEL="${ATTY_OLLAMA_MODEL:-qwen2.5-coder:1.5b}"

require_cmd curl

if ! curl -sS --max-time 2 -o /dev/null "$OLLAMA_HOST/api/tags"; then
    skip "ollama not reachable at $OLLAMA_HOST"
    exit 0
fi

# Confirm the model is pulled.
if ! curl -sS "$OLLAMA_HOST/api/tags" | python3 -c "
import json, sys
tags = json.load(sys.stdin).get('models', [])
names = [m['name'] for m in tags]
if not any(n.startswith('$OLLAMA_MODEL') for n in names):
    sys.exit(1)
"; then
    skip "ollama model $OLLAMA_MODEL not pulled (run 'ollama pull $OLLAMA_MODEL')"
    exit 0
fi

build_atty

# Build a config that targets the user's Ollama. Inert other modules
# so the dialog flow runs cleanly without security_guard interference.
# `zig build -Dconfig=` requires a path RELATIVE to the build root,
# so we write into the integration fixtures dir (gitignored).
mkdir -p "$REPO_ROOT/tests/integration/fixtures/build-tmp"
CONFIG_FILE="tests/integration/fixtures/build-tmp/ollama-dialog.zig"
trap 'rm -f "$BUILD_LOG" "$REPO_ROOT/$CONFIG_FILE"' EXIT

cat > "$REPO_ROOT/$CONFIG_FILE" <<ZIG
const atty = @import("atty");

pub const modules = .{
    atty.modules.llm.configure(.{
        .api_base = "$OLLAMA_HOST/v1",
        .models = &.{ .{ .name = "$OLLAMA_MODEL" } },
    }),
};

pub const statusbar: atty.StatusBar = .{
    .enabled = true,
    .base_text = "atty",
};
ZIG

# Rebuild atty with this config. config path must be repo-relative.
(cd "$REPO_ROOT" && zig build -Doptimize=ReleaseSafe -Dconfig="$CONFIG_FILE" >"$BUILD_LOG" 2>&1) || {
    cat "$BUILD_LOG" >&2
    fail "atty build with Ollama config failed"
}

# Pre-warm Ollama so cold-start latency doesn't blow the timeout.
# The first request after a cold daemon can take 10+ s; subsequent
# requests on a warm model are typically < 5 s.
curl -sS --max-time 30 -o /dev/null \
    "$OLLAMA_HOST/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$OLLAMA_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}" || true

# Drive atty under a real PTY using `script`, type a #: prompt, fire
# Alt+A (single-shot), wait for the LLM response, snapshot output.
# Alt+A is preferred over Alt+S because single-shot fires immediately
# on the current line; dialog mode is a persistent-mode toggle that
# requires a follow-up Enter.
TMP_OUT=$(mktemp)
{
    sleep 0.5
    printf 'PS1="$ "; clear\r'
    sleep 0.3
    printf '#: list files in /tmp'
    sleep 0.2
    printf '\x1ba'  # Alt+A = llm_exec_single (one-shot)
    # Generation time depends on model + hardware. 1.5b on CPU
    # typically takes 2-10 s post-warmup. Wait generously.
    sleep 30
    printf '\x1b\x15'  # Esc to cancel any in-flight, Ctrl+U to clear residue
    sleep 0.5
    printf 'exit\r'
} | script -qfec "$ATTY_BIN bash --norc --noprofile -i" "$TMP_OUT" >/dev/null 2>&1 || true

# Strip ANSI, look for evidence of an LLM-suggested command on the
# prompt. Qwen will likely suggest `ls /tmp` or similar.
PLAIN=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b[\\(].//g; s/\x1b\][^\x07]*\x07//g' "$TMP_OUT")
rm -f "$TMP_OUT"

# Look for "ls" or "find" in the output — the LLM should suggest
# SOMETHING file-listing-shaped for "list files in /tmp".
if ! echo "$PLAIN" | grep -qE "ls|find"; then
    echo "--- captured output (sanitized) ---" >&2
    echo "$PLAIN" | tail -20 >&2
    fail "Ollama dialog round-trip didn't produce a file-listing suggestion"
fi

pass "LLM dialog round-trip through Ollama ($OLLAMA_MODEL) produced a suggestion"
