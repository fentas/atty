#!/usr/bin/env bash
# Shared helpers for atty integration tests.
#
# A scenario sources this file and then uses:
#   build_guard [--features ...]   — `cargo build --release` if not fresh
#   build_atty                     — `zig build` if not fresh
#   start_guard [--tier2 ...] [--config ...] [...]
#                                  — boots atty-guard on a temp socket
#   stop_guard                     — kills the guard from start_guard
#   guard_socket                   — echoes the socket path
#   classify "<command>"           — round-trips one JSON-line classify RPC
#   expect_verdict "<safe|warn|block>"  on the LAST classify result
#   expect_category "<atom|...>"
#   expect_confidence_ge <float>
#   pass "<msg>"                   — print PASS line + return 0
#   fail "<msg>"                   — print FAIL line + return 1
#   skip "<reason>"                — print SKIP line + return 0 (treated
#                                    as success but flagged in the runner)
#   require_cmd <name>             — fail-skip if `name` isn't on PATH
#
# Globals set on first use:
#   REPO_ROOT       — git toplevel
#   GUARD_BIN       — path to atty-guard release binary
#   ATTY_BIN        — path to atty release binary
#   _GUARD_PID      — pid of the daemon started by start_guard (if any)
#   _GUARD_SOCKET   — UDS path
#   _LAST_RESPONSE  — last JSON-line response from `classify`

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ATTY_BIN="${REPO_ROOT}/zig-out/bin/atty"
GUARD_BIN="${REPO_ROOT}/atty-guard/target/release/atty-guard"

# Print helpers. `tee`-friendly — one line per status so the top-level
# runner can grep for PASS/FAIL/SKIP without scraping prose.
pass() {
    printf "PASS: %s\n" "$*"
    return 0
}
fail() {
    printf "FAIL: %s\n" "$*" >&2
    return 1
}
skip() {
    printf "SKIP: %s\n" "$*"
    return 0
}
require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        skip "missing dependency: $1"
        exit 0
    fi
}

# -----------------------------------------------------------------------
# Build helpers — idempotent. Cargo / Zig both no-op when artifact fresh.
# -----------------------------------------------------------------------

build_atty() {
    if [ -x "$ATTY_BIN" ] && [ -z "${ATTY_REBUILD:-}" ]; then return 0; fi
    (cd "$REPO_ROOT" && zig build -Doptimize=ReleaseSafe >/dev/null 2>&1)
}

# build_guard [--features=X,Y,Z]
# Default features: tier2-onnx,osv-live,atoms-fetch (matches release artifacts).
build_guard() {
    local features="tier2-onnx,osv-live,atoms-fetch"
    while [ $# -gt 0 ]; do
        case "$1" in
            --features=*) features="${1#--features=}"; shift ;;
            *) break ;;
        esac
    done
    if [ -x "$GUARD_BIN" ] && [ -z "${GUARD_REBUILD:-}" ]; then return 0; fi
    (cd "$REPO_ROOT/atty-guard" && \
        cargo build --release --features "$features" >/dev/null 2>&1)
}

# -----------------------------------------------------------------------
# Daemon lifecycle. Each scenario gets its own daemon on a unique socket
# so concurrent scenarios don't fight over the production
# `$XDG_RUNTIME_DIR/atty-guard.sock`.
# -----------------------------------------------------------------------

_GUARD_PID=""
_GUARD_SOCKET=""
_GUARD_LOG=""

start_guard() {
    build_guard
    local tmp; tmp="$(mktemp -d -t atty-guard-test.XXXXXX)"
    _GUARD_SOCKET="$tmp/sock"
    _GUARD_LOG="$tmp/log"
    "$GUARD_BIN" --socket "$_GUARD_SOCKET" "$@" >"$_GUARD_LOG" 2>&1 &
    _GUARD_PID=$!

    # Wait up to 2 s for the socket to appear. The daemon prints a
    # ready-line we could grep for, but the socket-exists check is
    # the load-bearing condition (the protocol can't connect before).
    local i=0
    while [ ! -S "$_GUARD_SOCKET" ] && [ $i -lt 40 ]; do
        sleep 0.05
        i=$((i + 1))
        if ! kill -0 "$_GUARD_PID" 2>/dev/null; then
            cat "$_GUARD_LOG" >&2
            fail "atty-guard exited before binding the socket"
            return 1
        fi
    done
    if [ ! -S "$_GUARD_SOCKET" ]; then
        cat "$_GUARD_LOG" >&2
        fail "atty-guard never bound $_GUARD_SOCKET"
        return 1
    fi
}

stop_guard() {
    if [ -n "${_GUARD_PID:-}" ] && kill -0 "$_GUARD_PID" 2>/dev/null; then
        kill "$_GUARD_PID" 2>/dev/null || true
        wait "$_GUARD_PID" 2>/dev/null || true
    fi
    _GUARD_PID=""
}

# Trap so a scenario that exits via `set -e` doesn't leak the daemon.
trap stop_guard EXIT INT TERM

guard_socket() {
    printf "%s" "$_GUARD_SOCKET"
}

guard_log() {
    [ -n "$_GUARD_LOG" ] && cat "$_GUARD_LOG"
}

# -----------------------------------------------------------------------
# UDS protocol — one-shot connect, send a classify request, read the
# reply, close. `socat` keeps the bash side simple; `nc` works too but
# its line-mode behaviour varies across distros.
# -----------------------------------------------------------------------

_LAST_RESPONSE=""

classify() {
    require_cmd socat
    local cmd="$1"
    # Escape the command for JSON.
    local json_cmd
    json_cmd=$(printf '%s' "$cmd" | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))')
    local req="{\"id\":1,\"method\":\"classify\",\"command\":${json_cmd}}"
    _LAST_RESPONSE=$(printf '%s\n' "$req" | socat -t 2 - "UNIX-CONNECT:$_GUARD_SOCKET" 2>/dev/null || true)
    if [ -z "$_LAST_RESPONSE" ]; then
        fail "no response from atty-guard for: $cmd"
        return 1
    fi
}

# JSON helper. Reads a top-level string field from $_LAST_RESPONSE.
# Avoids a hard dep on jq — python3 ships with every distro.
_jq() {
    local field="$1"
    python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('$field', ''))" "$_LAST_RESPONSE"
}

expect_verdict() {
    local want="$1"
    local got
    got=$(_jq verdict)
    if [ "$got" = "$want" ]; then return 0; fi
    fail "verdict mismatch: want=$want got=$got (response: $_LAST_RESPONSE)"
}

expect_category() {
    local want="$1"
    local got
    got=$(_jq category)
    if [ "$got" = "$want" ]; then return 0; fi
    fail "category mismatch: want=$want got=$got"
}

expect_confidence_ge() {
    local want="$1"
    local got
    got=$(_jq confidence)
    python3 -c "import sys; sys.exit(0 if float('$got') >= float('$want') else 1)" || {
        fail "confidence < $want: got=$got"
        return 1
    }
}

expect_reason_contains() {
    local needle="$1"
    local got
    got=$(_jq reason)
    case "$got" in
        *"$needle"*) return 0 ;;
        *) fail "reason does not contain '$needle': got='$got'"; return 1 ;;
    esac
}
