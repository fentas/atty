#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC1091
# Manual test runner for the security-guard + ghost-overlay PR
# series (#119-#127). Dispatches to per-PR test files under
# `scripts/tests/`. Each file defines a `main::<name>` function
# argsh's `:usage` dispatch invokes.
#
# Run from the repo root:
#   ./scripts/test.sh --help
#   ./scripts/test.sh ghost
#   ./scripts/test.sh all
set -euo pipefail

: "${PATH_BASE:="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}"
: "${PATH_BIN:="${PATH_BASE}/.bin"}"
: "${PATH_SCRIPTS:="${PATH_BASE}/scripts"}"
export PATH_BASE PATH_BIN PATH_SCRIPTS

ARGSH_SOURCE="${BASH_SOURCE[0]}"
source "${PATH_BIN}/argsh"

import ^tests/common
import ^tests/ghost
import ^tests/windsurf
import ^tests/atom-fetch
import ^tests/classifier
import ^tests/auto-block

main() {
  local -a usage=(
    'ghost@readonly'      'PR #122 — ghost overlay (Ctrl-A / End / Right-step)'
    'windsurf@readonly'   'PR #124 — Windsurf input compat (Space + Super+V)'
    'atom-fetch@readonly' 'PR #121 + #125 — V2-I fetcher + Sigma/LOLBAS'
    'classifier@readonly' 'PR #119 + #126 — AtomMatcher + V2-J accumulator'
    'auto-block@readonly' 'PR #127 — V2-J-2 opt-in auto-Block'
    'all@readonly'        'Run every section in order'
  )
  local -a args=()
  :usage "atty manual test runner" "${@}"
  "${usage[@]}"
  print_summary
}

# `all` is a wrapper around the other subcommands; lives here
# because it sequences across the imported handlers.
main::all() {
  local -a args=("${args[@]:-}")
  :args "Run every test section in order" "${@}"
  main::ghost
  main::windsurf
  main::atom-fetch
  main::classifier
  main::auto-block
}

[[ "${0}" != "${BASH_SOURCE[0]}" && -z "${ARGSH_SOURCE:-}" ]] || main "${@}"
