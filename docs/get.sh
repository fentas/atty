#!/usr/bin/env sh
# ─────────────────────────────────────────────────────────────────────────────
# atty source installer — https://atty.sh
#
# The Suckless way: clone the source, edit src/config.zig to pick your
# modules, compile, install. If you just want a binary, use
#     curl -fsSL https://bin.atty.sh | sh
#
# Usage:
#     curl -fsSL https://get.atty.sh | sh
#
# Env knobs (all optional):
#     ATTY_SRC             where to clone     (default: ~/.local/share/atty/src)
#     INSTALL_DIR          binary destination (default: ~/.local/bin)
#     ATTY_NONINTERACTIVE  skip the "edit config?" prompt
#     REPO_URL             alternative git remote
# ─────────────────────────────────────────────────────────────────────────────

set -eu

REPO_URL="${REPO_URL:-https://github.com/fentas/atty.git}"
SRC_DIR="${ATTY_SRC:-$HOME/.local/share/atty/src}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
ZIG_VERSION="0.16.0"
NONINTERACTIVE="${ATTY_NONINTERACTIVE:-}"

# ── ANSI helpers ────────────────────────────────────────────────────────────
red()    { printf '\033[1;31m%s\033[0m' "$*"; }
grn()    { printf '\033[1;32m%s\033[0m' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m' "$*"; }
dim()    { printf '\033[2m%s\033[0m'    "$*"; }
die()    { printf '%s %s\n' "$(red    '✗')" "$*" >&2; exit 1; }
info()   { printf '%s %s\n' "$(grn    '▸')" "$*"; }
warn()   { printf '%s %s\n' "$(yellow '⚠')" "$*"; }

# ── Interactive prompt that reads from the real TTY even under `curl|sh` ───
prompt_yes() {
    # $1 = message, default = yes. Echo "y" or "n".
    if [ -n "$NONINTERACTIVE" ] || [ ! -r /dev/tty ]; then
        printf 'y'
        return
    fi
    printf '%s [Y/n] ' "$1" >/dev/tty
    ans=""
    read -r ans </dev/tty || true
    case "$ans" in
        [Nn]|[Nn][Oo]) printf 'n' ;;
        *)             printf 'y' ;;
    esac
}

# ── Sanity ──────────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }
have git  || die "git is required (Suckless way needs the source)"
have curl || die "curl is required"
have tar  || die "tar is required"

# ── Platform → Zig tarball mapping ──────────────────────────────────────────
os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$os" in
    linux|macos|darwin) ;;
    *) die "unsupported OS: $os" ;;
esac
[ "$os" = "darwin" ] && os="macos"

arch=$(uname -m)
case "$arch" in
    x86_64|amd64)  arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) die "unsupported arch: $arch" ;;
esac

# ── Step 1: clone (or update) the source tree ──────────────────────────────
if [ -d "$SRC_DIR/.git" ]; then
    info "updating existing clone at $(dim "$SRC_DIR")"
    git -C "$SRC_DIR" fetch --quiet --tags origin
    # Stay on default branch tip unless caller has checked out something specific.
    branch=$(git -C "$SRC_DIR" symbolic-ref --quiet --short HEAD || echo "")
    if [ -n "$branch" ]; then
        git -C "$SRC_DIR" pull --quiet --ff-only origin "$branch" || \
            warn "git pull failed — building from existing checkout"
    fi
else
    info "cloning $(dim "$REPO_URL") → $(grn "$SRC_DIR")"
    mkdir -p "$(dirname "$SRC_DIR")"
    git clone --quiet "$REPO_URL" "$SRC_DIR"
fi

# ── Step 2: ensure Zig $ZIG_VERSION is on PATH (or in our cache) ───────────
zig_bin=""
if have zig; then
    cur=$(zig version 2>/dev/null || true)
    if [ "$cur" = "$ZIG_VERSION" ]; then
        zig_bin=$(command -v zig)
        info "using system zig $(grn "$cur")"
    else
        warn "system zig is $cur — atty wants $ZIG_VERSION, fetching it locally"
    fi
fi
if [ -z "$zig_bin" ]; then
    zig_dir="$HOME/.local/share/atty/zig-$ZIG_VERSION"
    if [ ! -x "$zig_dir/zig" ]; then
        info "downloading zig $(grn "$ZIG_VERSION") for $arch-$os"
        mkdir -p "$zig_dir"
        tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT INT TERM
        zig_url="https://ziglang.org/download/$ZIG_VERSION/zig-$arch-$os-$ZIG_VERSION.tar.xz"
        curl -fSL --progress-bar "$zig_url" -o "$tmp/zig.tar.xz" || die "zig download failed: $zig_url"
        tar -xJf "$tmp/zig.tar.xz" -C "$zig_dir" --strip-components=1
    fi
    zig_bin="$zig_dir/zig"
    info "using bundled zig at $(dim "$zig_bin")"
fi

# ── Step 3: invite user to edit src/config.zig (Suckless ethos) ────────────
cfg="$SRC_DIR/src/config.zig"
ans=$(prompt_yes "$(dim 'Edit') $(grn 'src/config.zig') $(dim '— pick modules and rules before build?')")
if [ "$ans" = "y" ] && [ -r /dev/tty ]; then
    editor="${EDITOR:-${VISUAL:-vi}}"
    info "opening $(grn "$editor") on $(dim "$cfg")"
    "$editor" "$cfg" </dev/tty >/dev/tty 2>&1 || warn "$editor exited non-zero"
fi

# ── Step 4: build ───────────────────────────────────────────────────────────
# On Linux we cross-compile to Zig's bundled glibc to dodge mismatched
# host crt1 (SFrame relocations on newer distros). Harmless on stock systems.
build_target=""
if [ "$os" = "linux" ]; then
    build_target="-Dtarget=$arch-linux-gnu"
fi

info "building (ReleaseSafe) — this takes ~5–15 s"
( cd "$SRC_DIR" && "$zig_bin" build -Doptimize=ReleaseSafe $build_target )

# ── Step 5: install ─────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"
install -m 0755 "$SRC_DIR/zig-out/bin/atty" "$INSTALL_DIR/atty"

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

$(dim '# Source lives at:') $SRC_DIR
$(dim '#   Edit src/config.zig anytime, then re-run:') $zig_bin build $build_target
$(dim '#   Or re-run this installer (it does a fast-forward pull):')
$(dim '#     ') curl -fsSL https://get.atty.sh | sh

$(dim '# In ~/.config/ghostty/config:')
command = atty bash

$(dim '# Or in ~/.bashrc, to wrap on demand:')
if [[ -z "\${ATTY}" ]] && command -v atty >/dev/null; then
    exec atty bash
fi

$(dim 'Docs:') https://atty.sh
EOF
