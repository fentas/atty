# syntax=docker/dockerfile:1.7
#
# Multi-architecture build for atty.
#
# We rely on Zig's cross-compilation rather than QEMU emulation: the
# builder always runs on $BUILDPLATFORM (the host arch), and Zig
# targets $TARGETARCH. Result: amd64 and arm64 builds take roughly
# the same time, both run native CPU.
#
# Useful invocations:
#   docker build -t atty:latest .                          # local arch
#   docker buildx build --platform linux/amd64,linux/arm64 . # multi-arch
#   docker build --target builder -t atty:builder .         # binary only
#
# Build args:
#   ZIG_VERSION   - default 0.16.0
#   BUILDARCH     - host arch for the Zig toolchain (auto)
#   TARGETARCH    - destination arch (auto, set by buildx)

# ---- Stage 1: builder ------------------------------------------------------
FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS builder

ARG ZIG_VERSION=0.16.0
ARG BUILDARCH
ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Download a Zig toolchain matching the *host* arch.
RUN set -eux; \
    case "${BUILDARCH:-amd64}" in \
        amd64) ZIG_HOST="x86_64-linux"  ;; \
        arm64) ZIG_HOST="aarch64-linux" ;; \
        *)     echo "Unsupported BUILDARCH=${BUILDARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_HOST}-${ZIG_VERSION}.tar.xz" \
      | tar -xJ -C /opt; \
    ln -s "/opt/zig-${ZIG_HOST}-${ZIG_VERSION}/zig" /usr/local/bin/zig

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src

# Build a statically-linked musl binary for the target arch.
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
        amd64) ZIG_TARGET="x86_64-linux-musl"  ;; \
        arm64) ZIG_TARGET="aarch64-linux-musl" ;; \
        *)     echo "Unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    zig build -Doptimize=ReleaseSafe -Dtarget="${ZIG_TARGET}"

# ---- Stage 2: runtime ------------------------------------------------------
#
# Alpine has busybox /bin/sh, which is enough for `atty` to spawn a
# shell inside the container. The atty binary itself is musl-static and
# has no library dependencies of its own.
FROM alpine:3.22 AS runtime

# Optional: include bash + zsh for users who want them inside the
# container. Lean — total image stays well under 20 MB.
RUN apk add --no-cache bash

COPY --from=builder /src/zig-out/bin/atty /usr/local/bin/atty

ENTRYPOINT ["/usr/local/bin/atty"]
