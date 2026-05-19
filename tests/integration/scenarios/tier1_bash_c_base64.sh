#!/usr/bin/env bash
# Tier-1: long base64-shaped `bash -c "<arg>"` arg trips the obfuscated-
# payload detector. A short arg (normal `bash -c "ls"`) must NOT trip
# it, otherwise users running legitimate one-liners get spurious warns.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

start_guard --tier2 stub

# Long base64-ish arg: 80+ chars, alphabet of letters+digits+`=`. This
# is the shape malware uses to evade plaintext scanners.
PAYLOAD="QWxsIHlvdXIgYmFzaCBhcmUgYmVsb25nIHRvIHVzLiBUaGlzIGlzIGEgbG9uZyBiYXNlNjQgcGF5bG9hZCB0byB0cmlnZ2VyIHRoZSBiYXNoLWMtYjY0IHJ1bGUuPT0="
classify "bash -c \"$PAYLOAD\""
expect_verdict warn
expect_category bash_c_base64

# A short, plain command MUST stay Safe (regex false-positive guard).
classify "bash -c \"ls -la\""
expect_verdict safe

pass "Tier-1 bash -c base64 fires on long obfuscated arg, stays Safe on plain"
