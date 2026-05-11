#!/usr/bin/env sh
#
# One-shot install: build atty inside Docker, drop the binary in ./dist/.
# Use this when you want the binary without installing Zig on your host.
#
# Customise the target by setting TARGET (e.g. x86_64-linux-musl for a
# fully static binary).

set -eu

TARGET="${TARGET:-x86_64-linux-gnu}"
IMAGE="${IMAGE:-atty:builder}"
OUT_DIR="${OUT_DIR:-$PWD/dist}"

echo "▶ Building $IMAGE (target: $TARGET) …"
docker build --build-arg "TARGET=$TARGET" -t "$IMAGE" --target builder .

mkdir -p "$OUT_DIR"
echo "▶ Extracting binary to $OUT_DIR/atty …"
docker run --rm -v "$OUT_DIR:/out" "$IMAGE" cp /src/zig-out/bin/atty /out/atty

echo "✓ Done. Run with:  $OUT_DIR/atty"
echo "  Copy to your \$PATH, e.g.:  sudo install -m 0755 $OUT_DIR/atty /usr/local/bin/atty"
