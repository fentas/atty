#!/usr/bin/env sh
#
# One-shot install: build atty inside Docker, drop the binary in ./dist/.
# Use this when you want the binary without installing Zig on your host.
#
# The Dockerfile selects the Zig target from the build platform's
# TARGETARCH (amd64 → x86_64-linux-musl, arm64 → aarch64-linux-musl) and
# always produces a fully static musl binary. To cross-build, pick the
# platform with buildx, e.g. `docker buildx build --platform linux/arm64`.

set -eu

IMAGE="${IMAGE:-atty:builder}"
OUT_DIR="${OUT_DIR:-$PWD/dist}"

echo "▶ Building $IMAGE …"
docker build -t "$IMAGE" --target builder .

mkdir -p "$OUT_DIR"
echo "▶ Extracting binary to $OUT_DIR/atty …"
docker run --rm -v "$OUT_DIR:/out" "$IMAGE" cp /src/zig-out/bin/atty /out/atty

echo "✓ Done. Run with:  $OUT_DIR/atty"
echo "  Copy to your \$PATH, e.g.:  sudo install -m 0755 $OUT_DIR/atty /usr/local/bin/atty"
