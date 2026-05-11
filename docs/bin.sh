#!/usr/bin/env sh
# ─────────────────────────────────────────────────────────────────────────────
# atty binary installer — https://atty.sh
#
# Usage:
#     curl -fsSL https://bin.atty.sh | sh
#
# Env knobs (all optional):
#     INSTALL_DIR   target dir (default: $HOME/.local/bin)
#     ATTY_VERSION  pin a specific release (default: latest)
# ─────────────────────────────────────────────────────────────────────────────

set -eu

REPO="fentas/atty"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
VERSION="${ATTY_VERSION:-latest}"

red() { printf '\033[1;31m%s\033[0m' "$*"; }
grn() { printf '\033[1;32m%s\033[0m' "$*"; }
dim() { printf '\033[2m%s\033[0m' "$*"; }

die()  { printf '%s %s\n' "$(red '✗')" "$*" >&2; exit 1; }
info() { printf '%s %s\n' "$(grn '▸')" "$*"; }

# ── Detect platform ─────────────────────────────────────────────────────────
os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$os" in
    linux) ;;
    darwin) die "macOS support is on the roadmap. Build from source: https://github.com/${REPO}" ;;
    *) die "unsupported OS: $os" ;;
esac

arch=$(uname -m)
case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) die "unsupported arch: $arch (only x86_64 and aarch64 today)" ;;
esac

asset="atty-${os}-${arch}"

# ── Tools ───────────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }
have curl || die "curl is required"

if have sha256sum; then
    sha_cmd='sha256sum'
elif have shasum; then
    sha_cmd='shasum -a 256'
else
    die "sha256sum or shasum is required"
fi

# ── URLs ────────────────────────────────────────────────────────────────────
if [ "$VERSION" = "latest" ]; then
    url="https://github.com/${REPO}/releases/latest/download/${asset}"
else
    url="https://github.com/${REPO}/releases/download/v${VERSION#v}/${asset}"
fi
sum_url="${url}.sha256"

# ── Download ────────────────────────────────────────────────────────────────
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

info "downloading $(dim "$asset")"
curl -fSL --progress-bar "$url"     -o "$tmp/atty"        || die "download failed: $url"
curl -fsSL                "$sum_url" -o "$tmp/atty.sha256" || die "checksum fetch failed"

# ── Verify ──────────────────────────────────────────────────────────────────
info "verifying checksum"
expected=$(awk '{print $1}' "$tmp/atty.sha256")
actual=$($sha_cmd "$tmp/atty" | awk '{print $1}')
[ "$expected" = "$actual" ] || die "checksum mismatch (expected $expected, got $actual)"

# ── Install ─────────────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"
mv "$tmp/atty" "$INSTALL_DIR/atty"
chmod 0755 "$INSTALL_DIR/atty"

installed_version=$("$INSTALL_DIR/atty" --version 2>/dev/null | head -n1 || true)
info "installed $(grn "$INSTALL_DIR/atty") ${installed_version:+($installed_version)}"

# ── PATH hint ───────────────────────────────────────────────────────────────
case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *)
        printf '\n%s %s is not on $PATH.\n' "$(red '⚠')" "$INSTALL_DIR"
        printf '   Add this to your shell rc:\n\n'
        printf '       export PATH="%s:$PATH"\n\n' "$INSTALL_DIR"
        ;;
esac

# ── Next steps ──────────────────────────────────────────────────────────────
cat <<EOF

$(dim '# In ~/.config/ghostty/config (or your terminal config):')
command = atty bash

$(dim '# Or in ~/.bashrc, to wrap on demand:')
if [[ -z "\${ATTY}" ]] && command -v atty >/dev/null; then
    exec atty bash
fi

$(dim 'Docs:') https://atty.sh
EOF
