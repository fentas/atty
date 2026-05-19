#!/usr/bin/env bash
# Tier-1: `npm install <flagged-pkg>` produces Warn @ 1.0 when the
# package is on `flagged_npm.txt`. Bare `npm install <unflagged>`
# stays Safe (the regex matches but only emits a hit if the package
# is on the flagged list — no false positives on routine installs).

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

start_guard --tier2 stub

# event-stream is the canonical compromised-npm-package example,
# always at the top of flagged_npm.txt.
classify "npm install event-stream"
expect_verdict warn
expect_category npm_unsafe_install
expect_confidence_ge 1.0
expect_reason_contains "event-stream"

# Routine install of an unflagged package must NOT warn — this is
# the false-positive guard. A user running `npm install lodash`
# in atty hundreds of times a week would lose trust in the prompts.
classify "npm install lodash"
expect_verdict safe

# pnpm / yarn synonyms also fire on flagged packages.
classify "pnpm add event-stream"
expect_verdict warn

classify "yarn add event-stream"
expect_verdict warn

pass "Tier-1 npm_unsafe_install: warns on flagged, ignores routine, covers pnpm/yarn"
