#!/usr/bin/env bash
# Regenerate the per-feature demo GIFs in docs/assets/atty-<feature>.gif.
#
# Two stages: record the casts (the e2e runner drives atty under a PTY and
# writes tests/demo/<feature>/golden/cast.json), then render each with agg.
# The scenarios type at human cadence (`type "..." irregular`, from the ttysnap
# `typing` module) so the GIFs animate naturally; agg caps idle gaps so the
# pauses stay snappy.
#
# Requires agg:  cargo install --locked --git https://github.com/asciinema/agg --tag v1.9.0
# Optional env:  ZIG_TARGET (default -Dtarget=x86_64-linux-gnu), AGG_THEME (monokai).
set -euo pipefail
cd "$(dirname "$0")/.."

export PATH="$HOME/.cargo/bin:$PATH"
TARGET="${ZIG_TARGET:--Dtarget=x86_64-linux-gnu}"
THEME="${AGG_THEME:-monokai}"

# The e2e runner rebuilds atty once per scenario via a fresh `zig build install`;
# that child reads ATTY_E2E_BUILD_FLAGS (not -Dtarget), so propagate the target
# to it too — otherwise ZIG_TARGET would only affect the outer build and the
# per-scenario atty would link natively (which fails on some toolchains, e.g.
# Arch's gcc-16 crt1). Respect an already-exported value.
export ATTY_E2E_BUILD_FLAGS="${ATTY_E2E_BUILD_FLAGS:-$TARGET}"

if ! command -v agg >/dev/null 2>&1; then
  echo "error: agg not found — cargo install --locked --git https://github.com/asciinema/agg --tag v1.9.0" >&2
  exit 1
fi

echo ">> recording casts (zig build demo -- --update)"
rm -f /tmp/atty-demo-*            # fresh history files → deterministic ghost suggestions
zig build demo "$TARGET" -- --update

# Strip OSC 7 cwd reports from every cast — atty's shell integration (sourced by
# the tour) emits `ESC ]7;file://<host><path> BEL` each prompt, which would bake
# the recording machine's hostname + checkout path into the committed cast. The
# sequence is non-printing, so removing it doesn't change the rendered GIF; it
# just keeps the cast portable + reproducible.
echo ">> stripping OSC 7 cwd reports from casts"
python3 - tests/demo/*/golden/cast.json <<'PY'
import re, sys
osc7 = re.compile(r'\\u001b\]7;.*?\\u0007')
for path in sys.argv[1:]:
    text = open(path).read()
    open(path, "w").write(osc7.sub("", text))
PY

mkdir -p docs/assets
echo ">> rendering GIFs (agg, theme=$THEME)"
for cast in tests/demo/*/golden/cast.json; do
  feat="$(basename "$(dirname "$(dirname "$cast")")")"
  agg --theme "$THEME" --font-size 16 --idle-time-limit 1.5 "$cast" "docs/assets/atty-$feat.gif"
  echo "   docs/assets/atty-$feat.gif"
done
echo ">> done"
