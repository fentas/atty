#!/usr/bin/env bash
# Regenerate the per-feature demo GIFs in docs/assets/atty-<feature>.gif.
#
# Two stages: record the casts (the e2e runner drives atty under a PTY and
# writes tests/demo/<feature>/golden/cast.json), then render each with agg.
# The scenarios type at human cadence (`type "..." irregular`, from the ttysnap
# `typing` module) so the GIFs animate naturally; agg caps idle gaps so the
# pauses stay snappy.
#
# Requires agg:  cargo install --locked --git https://github.com/asciinema/agg
# Optional env:  ZIG_TARGET (default -Dtarget=x86_64-linux-gnu), AGG_THEME (monokai).
set -euo pipefail
cd "$(dirname "$0")/.."

export PATH="$HOME/.cargo/bin:$PATH"
TARGET="${ZIG_TARGET:--Dtarget=x86_64-linux-gnu}"
THEME="${AGG_THEME:-monokai}"

if ! command -v agg >/dev/null 2>&1; then
  echo "error: agg not found — cargo install --locked --git https://github.com/asciinema/agg" >&2
  exit 1
fi

echo ">> recording casts (zig build demo -- --update)"
rm -f /tmp/atty-demo-*            # fresh history files → deterministic ghost suggestions
zig build demo "$TARGET" -- --update

mkdir -p docs/assets
echo ">> rendering GIFs (agg, theme=$THEME)"
for cast in tests/demo/*/golden/cast.json; do
  feat="$(basename "$(dirname "$(dirname "$cast")")")"
  agg --theme "$THEME" --font-size 16 --idle-time-limit 1.5 "$cast" "docs/assets/atty-$feat.gif"
  echo "   docs/assets/atty-$feat.gif"
done
echo ">> done"
