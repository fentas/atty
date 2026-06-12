#!/usr/bin/env bash
# atty-guard installer — system-daemon mode.
#
# Installs the binary to /usr/local/bin, creates the dedicated `atty`
# user/group, installs the systemd unit to /etc/systemd/system/, and
# enables it. Requires root (re-execs via sudo if not already root).
#
# WHY system daemon instead of systemd-user: atom + URL trust state
# influences detection. A user-writable trust file is a DOS vector
# (process running as $USER could poison atoms with common commands
# and force atty-guard to be disabled). atty:atty-owned state under
# /var/lib/atty-guard/ keeps mutations outside the user's write
# reach. The mutation API (planned: `sudo atty-guard atoms add/...`
# CLI subcommands) lands in PR #141; PR #140 only sets up the
# foundation — daemon under the dedicated user, state dirs in place.
#
# Build first:
#   cd atty-guard && cargo build --release
#
# Install:
#   sudo ./contrib/install.sh
#   (or:  make install-guard  — wraps this)
#
# To remove:
#   sudo systemctl disable --now atty-guard
#   sudo rm -f /usr/local/bin/atty-guard /etc/systemd/system/atty-guard.service
#   sudo rm -rf /var/lib/atty-guard
#   sudo userdel atty   # if you also want to remove the user
#
# Users who want to talk to the daemon must be in the `atty` group:
#   sudo usermod -aG atty $USER
#   (re-login for the group change to take effect)

set -euo pipefail

# Parse args (before sudo re-exec so the flag forwards through).
WITH_EBPF=0
WITHOUT_EBPF=0
WITH_NETWORK=0
WITHOUT_NETWORK=0
for arg in "$@"; do
    case "$arg" in
        --with-ebpf)
            WITH_EBPF=1
            ;;
        --without-ebpf)
            WITHOUT_EBPF=1
            ;;
        --with-network)
            WITH_NETWORK=1
            ;;
        --without-network)
            WITHOUT_NETWORK=1
            ;;
        --help|-h)
            sed -n '2,32p' "$0" | sed 's/^# \?//'
            echo
            echo "Flags:"
            echo "  --with-ebpf      Compile + install the kernel BPF object to"
            echo "                   /usr/lib/atty-guard and install the systemd"
            echo "                   drop-in (CAP_BPF + CAP_PERFMON + CAP_MAC_ADMIN,"
            echo "                   SystemCallFilter widening, --enable-ebpf on"
            echo "                   ExecStart). Requires: the binary built with"
            echo "                   --features ebpf; kernel BTF at"
            echo "                   /sys/kernel/btf/vmlinux; clang + bpftool on"
            echo "                   PATH. Hard-fails (not silent fallback) if any"
            echo "                   prerequisite is missing."
            echo "  --without-ebpf   Explicitly remove the eBPF drop-in AND the"
            echo "                   installed BPF object (/usr/lib/atty-guard/"
            echo "                   atty_guard.bpf.o) if present. Use when"
            echo "                   downgrading from an ebpf install: without this"
            echo "                   flag a plain re-install leaves the existing"
            echo "                   drop-in in place (warn-only)."
            echo "  --with-network   Install the network systemd drop-in (relaxes"
            echo "                   PrivateNetwork=yes + adds AF_INET/AF_INET6)."
            echo "                   Required for osv-live and atoms-fetch features."
            echo "                   Auto-detected: if the binary has either feature"
            echo "                   built in (via --print-features), the drop-in"
            echo "                   is installed even without this flag — pass it"
            echo "                   only to force install regardless of features."
            echo "  --without-network  Explicitly remove the network drop-in. Use"
            echo "                   if you previously installed network features"
            echo "                   and are now downgrading to a network-free build."
            exit 0
            ;;
        *)
            echo "error: unknown flag: $arg (try --help)" >&2
            exit 1
            ;;
    esac
done

if [[ $WITH_EBPF -eq 1 && $WITHOUT_EBPF -eq 1 ]]; then
    echo "error: --with-ebpf and --without-ebpf are mutually exclusive" >&2
    exit 1
fi
if [[ $WITH_NETWORK -eq 1 && $WITHOUT_NETWORK -eq 1 ]]; then
    echo "error: --with-network and --without-network are mutually exclusive" >&2
    exit 1
fi

# Re-exec under sudo if not already root. This mirrors the pattern
# in other system installers (e.g. rustup, ohmyzsh) — keep the
# user's PWD and SHELL invocation intact across the elevation.
if [[ $EUID -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "error: this installer requires root. install sudo or run as root." >&2
        exit 1
    fi
    # Drop the caller's env (no `-E`). The default sudo `env_reset`
    # behavior is what we want — passing `-E` would leak LD_PRELOAD /
    # LD_LIBRARY_PATH / similar from the unprivileged caller into the
    # root-EUID re-exec, an obvious privesc surface. This installer
    # reads no caller env (REPO_ROOT is derived from $0 and all other
    # paths are hardcoded), so env_reset is safe.
    exec sudo -- bash "$0" "$@"
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_SRC="$REPO_ROOT/target/release/atty-guard"

# System install paths. Hardcoded — system-daemon installs don't
# honour PREFIX because the systemd unit references absolute paths
# and the dedicated user's home base is a known FHS location.
BIN_DST="/usr/local/bin/atty-guard"
UNIT_SRC="$REPO_ROOT/contrib/atty-guard.service"
UNIT_DST="/etc/systemd/system/atty-guard.service"
STATE_DIR="/var/lib/atty-guard"
CONFIG_DIR="/etc/atty-guard"
PINS_EXAMPLE_SRC="$REPO_ROOT/contrib/atoms.pins.toml.example"
PINS_EXAMPLE_DST="$CONFIG_DIR/atoms.pins.toml.example"

if [[ ! -x "$BIN_SRC" ]]; then
    echo "error: $BIN_SRC not found." >&2
    echo "       run 'cd atty-guard && cargo build --release' first." >&2
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    echo "error: systemctl not on \$PATH — this installer assumes systemd." >&2
    exit 1
fi

# Create atty system user + group (idempotent — getent is a no-op if
# they already exist). System user means UID < 1000, no home dir, no
# login shell — the standard dedicated-daemon pattern (postgres,
# postfix, etc.).
if ! getent group atty >/dev/null 2>&1; then
    groupadd --system atty
    echo "created system group 'atty'"
fi
if ! getent passwd atty >/dev/null 2>&1; then
    useradd --system --gid atty --no-create-home \
        --home-dir /nonexistent --shell /usr/sbin/nologin \
        --comment "atty-guard sidecar daemon" atty
    echo "created system user 'atty'"
fi

# Atomic binary install.
install -o root -g root -m 0755 "$BIN_SRC" "$BIN_DST.tmp.$$"
mv -f "$BIN_DST.tmp.$$" "$BIN_DST"
echo "installed $BIN_DST"

# State directory — atom files + URL decisions live here. atty:atty
# owned, mode 0750 (atty user can read/write, atty group can read,
# others nothing). The daemon refuses to load atom files that don't
# match this ownership at startup.
install -d -o atty -g atty -m 0750 "$STATE_DIR"
echo "ensured $STATE_DIR (atty:atty 0750)"

# Admin policy directory — operator-set commit pins for the atom
# corpus live here. Owned root:root 0755 so admins write via sudo;
# daemon reads via ProtectSystem=strict's default /etc read-only
# exposure (no bind-mount needed). Pin file itself absent by
# default — operators opt in by copying the example and editing it.
install -d -o root -g root -m 0755 "$CONFIG_DIR"
echo "ensured $CONFIG_DIR (root:root 0755)"
if [[ -f "$PINS_EXAMPLE_SRC" ]]; then
    install -o root -g root -m 0644 "$PINS_EXAMPLE_SRC" "$PINS_EXAMPLE_DST"
    echo "installed $PINS_EXAMPLE_DST"
fi

# Service unit.
install -o root -g root -m 0644 "$UNIT_SRC" "$UNIT_DST"
echo "installed $UNIT_DST"

# eBPF drop-in (--with-ebpf only). Lives at
# /etc/systemd/system/atty-guard.service.d/ebpf.conf so the
# baseline unit stays vanilla — operators can drop the override
# back to ExecStart-only by `rm` of the drop-in, no edit needed.
EBPF_DROPIN_DIR="/etc/systemd/system/atty-guard.service.d"
EBPF_DROPIN_FILE="$EBPF_DROPIN_DIR/ebpf.conf"
if [[ $WITH_EBPF -eq 1 ]]; then
    # Verify the binary was built with the feature. The
    # --print-features probe (added in #145) emits one feature per
    # line. Distinguish two failure modes that both produce a
    # non-zero grep:
    #   A) binary is too old to support --print-features at all
    #      (the flag was added in #145, mid-2026). Operator needs
    #      to upgrade atty-guard before we can certify the feature.
    #   B) binary supports the flag but `ebpf` isn't in its output
    #      — feature wasn't built in. Operator needs the right
    #      GUARD_FEATURES on their rebuild.
    # Probe in two steps so the error message points at the right
    # remedy.
    if ! "$BIN_DST" --print-features >/dev/null 2>&1; then
        echo "error: --with-ebpf passed but $BIN_DST does not support --print-features." >&2
        echo "       upgrade your atty-guard install — the probe landed in issue #145." >&2
        exit 1
    fi
    if ! "$BIN_DST" --print-features 2>/dev/null | grep -qx ebpf; then
        echo "error: --with-ebpf passed but binary lacks the ebpf cargo feature." >&2
        echo "       rebuild with:" >&2
        echo "         cd atty-guard && cargo build --release --features ebpf" >&2
        echo "       (or via the Makefile: make build-guard GUARD_FEATURES=...,ebpf)" >&2
        exit 1
    fi

    # Build + install the kernel-side BPF object. The daemon's loader
    # (src/ebpf.rs::locate_bpf_object) searches the binary's dir, the
    # build tree, and /usr/lib/atty-guard — NONE of which the installer
    # populated before. Without the .o, `--enable-ebpf` finds nothing,
    # logs ObjectMissing, and falls back to the in-memory V2-A map: an
    # operator who asked for --with-ebpf gets ZERO kernel enforcement
    # with only a journal line. Hard-fail here instead so the gap is
    # loud, not silent.
    BPF_SRC_DIR="$REPO_ROOT/ebpf"
    BPF_LIB_DIR="/usr/lib/atty-guard"
    BPF_OBJ_DST="$BPF_LIB_DIR/atty_guard.bpf.o"
    if [[ ! -r /sys/kernel/btf/vmlinux ]]; then
        echo "error: --with-ebpf requires kernel BTF at /sys/kernel/btf/vmlinux" >&2
        echo "       (CONFIG_DEBUG_INFO_BTF=y). This kernel lacks it — the CO-RE" >&2
        echo "       BPF object can't be compiled. Use a BTF-enabled kernel or omit" >&2
        echo "       --with-ebpf to run in V2-A (in-memory) mode." >&2
        exit 1
    fi
    for _tool in make clang bpftool; do
        if ! command -v "$_tool" >/dev/null 2>&1; then
            echo "error: --with-ebpf needs '$_tool' on PATH to compile atty_guard.bpf.o." >&2
            echo "       Debian/Ubuntu: apt-get install make clang libbpf-dev linux-tools-common" >&2
            exit 1
        fi
    done
    echo "building atty_guard.bpf.o (clang BPF target + BTF CO-RE)…"
    # Clean up the in-tree build artifacts on EVERY exit from here on
    # (success or failure): we compile under sudo/root, so leaving a
    # root-owned vmlinux.h / .o in the (user-owned) checkout would break
    # a later non-root `make`. Must cover the make-failure path too, not
    # just success.
    _bpf_build_clean() { rm -f "$BPF_SRC_DIR/vmlinux.h" "$BPF_SRC_DIR/atty_guard.bpf.o"; }
    # Force-regenerate vmlinux.h from THIS kernel's BTF: the Makefile's
    # `vmlinux.h` target has no prerequisites, so an existing (possibly
    # stale, old-kernel) header would otherwise be reused as-is. Clean
    # any prior copy first so the dump always reflects the running kernel.
    _bpf_build_clean
    if ! make -C "$BPF_SRC_DIR" vmlinux.h all; then
        _bpf_build_clean
        echo "error: failed to compile atty_guard.bpf.o (see make output above)." >&2
        exit 1
    fi
    if [[ ! -f "$BPF_SRC_DIR/atty_guard.bpf.o" ]]; then
        _bpf_build_clean
        echo "error: make reported success but $BPF_SRC_DIR/atty_guard.bpf.o is missing." >&2
        exit 1
    fi
    install -d -o root -g root -m 0755 "$BPF_LIB_DIR"
    install -o root -g root -m 0644 "$BPF_SRC_DIR/atty_guard.bpf.o" "$BPF_OBJ_DST"
    echo "installed $BPF_OBJ_DST"
    _bpf_build_clean

    install -d -o root -g root -m 0755 "$EBPF_DROPIN_DIR"
    # Heredoc uses unquoted EOF so $BIN_DST expands — keeps the
    # ExecStart path in sync with the actual install location (the
    # installer hardcodes /usr/local/bin today but might honour a
    # PREFIX in the future; the drop-in shouldn't bake the literal).
    # No other variables need expansion; backslash-escape any
    # accidental shell metachars inside the body to keep them
    # literal.
    cat > "$EBPF_DROPIN_FILE.tmp.$$" <<EOF
# atty-guard eBPF drop-in. Generated by \`install.sh --with-ebpf\`.
# Lifts the baseline unit's sandbox restrictions enough to load
# BPF programs (LSM hook + execve tracepoint + AF_ALG tracepoint
# — see atty-guard/ebpf/README.md). Remove this file to revert
# to the no-eBPF V2-A behaviour (in-memory threat map only).
[Service]
# CAP_BPF gates BPF_PROG_LOAD + BPF_MAP_CREATE; CAP_PERFMON gates
# perf_event_open used by tracepoint attach. CAP_MAC_ADMIN is
# REQUIRED to load a BPF_PROG_TYPE_LSM program (the bprm_check_security
# hook) — without it the LSM attach returns EPERM, the whole load
# errors, and the daemon falls back to no kernel enforcement. Linux
# ≥ 5.8 split these out of CAP_SYS_ADMIN so daemons don't need the
# everything-capability for a narrow BPF need.
AmbientCapabilities=CAP_BPF CAP_PERFMON CAP_MAC_ADMIN

# The baseline \`SystemCallFilter=@system-service\` excludes bpf()
# and perf_event_open() (both live in @privileged); widening the
# allowlist with the two specific syscalls keeps the rest of the
# seccomp profile intact.
SystemCallFilter=bpf perf_event_open

# Default unit has RestrictNamespaces=yes which blocks BPF
# map types that need namespace access (cgroup maps in
# particular). Clearing is wider than strictly needed but matches
# the minimal viable config; tighten later if BPF_MAP_TYPE usage
# narrows.
RestrictNamespaces=

# Re-emit ExecStart with --enable-ebpf so the daemon actually
# attaches the programs at startup (the flag is on the CLI
# unconditionally, but without it the loader is skipped — see
# main.rs's enable_ebpf gate).
ExecStart=
ExecStart=$BIN_DST --enable-ebpf
EOF
    mv -f "$EBPF_DROPIN_FILE.tmp.$$" "$EBPF_DROPIN_FILE"
    chmod 0644 "$EBPF_DROPIN_FILE"
    echo "installed $EBPF_DROPIN_FILE"
elif [[ $WITHOUT_EBPF -eq 1 ]]; then
    if [[ -f "$EBPF_DROPIN_FILE" ]]; then
        rm -f "$EBPF_DROPIN_FILE"
        echo "removed $EBPF_DROPIN_FILE (--without-ebpf)"
        # Also try the parent dir — `rmdir` is a no-op if other
        # drop-ins live there (e.g. an operator's custom override),
        # so this is safe.
        rmdir "$EBPF_DROPIN_DIR" 2>/dev/null || true
    else
        echo "note: no eBPF drop-in at $EBPF_DROPIN_FILE — nothing to remove."
    fi
    # Drop the installed BPF object too so a later plain `--enable-ebpf`
    # can't load a stale object compiled against an old kernel's BTF.
    if [[ -f /usr/lib/atty-guard/atty_guard.bpf.o ]]; then
        rm -f /usr/lib/atty-guard/atty_guard.bpf.o
        echo "removed /usr/lib/atty-guard/atty_guard.bpf.o (--without-ebpf)"
        rmdir /usr/lib/atty-guard 2>/dev/null || true
    fi
elif [[ -f "$EBPF_DROPIN_FILE" ]]; then
    # Operator previously ran --with-ebpf, now re-running plain.
    # Leave the drop-in alone but warn — explicit removal via
    # --without-ebpf is the documented path.
    echo "note: existing eBPF drop-in at $EBPF_DROPIN_FILE left in place."
    echo "      pass --with-ebpf to re-confirm, --without-ebpf to remove."
fi

# Network drop-in. The baseline unit hard-locks the daemon out of
# the network (PrivateNetwork=yes + RestrictAddressFamilies=AF_UNIX)
# because the V2-A threat model didn't need network. V2-F / V2-I
# features (osv-live + atoms-fetch) DO need outbound HTTPS. The
# drop-in relaxes both restrictions. Auto-detect when either feature
# is built in unless the operator explicitly opted out via
# --without-network. --with-network forces install regardless of
# detected features (useful when adding the drop-in ahead of a
# rebuild with the features enabled).
# Drop-in dir is shared with the ebpf branch above — reuse the
# literal so a future relocation has a single touch point.
NETWORK_DROPIN_FILE="$EBPF_DROPIN_DIR/network.conf"

# Detect whether the installed binary needs network. --print-features
# was added in #145; older binaries silently skip the detection (we
# can't tell what they were built with).
NEEDS_NETWORK=0
PROBE_UNSUPPORTED=0
if "$BIN_DST" --print-features >/dev/null 2>&1; then
    if "$BIN_DST" --print-features 2>/dev/null | grep -qxE 'osv-live|atoms-fetch'; then
        NEEDS_NETWORK=1
    fi
else
    PROBE_UNSUPPORTED=1
fi

# Hint operators when the auto-detect can't run: the network
# drop-in won't be installed, but if their old binary IS a
# network build they'll see silent "endpoint unreachable" at
# runtime. The note is suppressed when the operator has
# explicitly opted in or out via flags — they've already
# decided.
if [[ $PROBE_UNSUPPORTED -eq 1 && $WITH_NETWORK -eq 0 && $WITHOUT_NETWORK -eq 0 ]]; then
    echo "note: $BIN_DST is older than the --print-features probe (#145)." >&2
    echo "      auto-detect cannot tell whether osv-live/atoms-fetch are built in." >&2
    echo "      if either feature IS present, re-run with --with-network." >&2
fi

if [[ $WITH_NETWORK -eq 1 || ($NEEDS_NETWORK -eq 1 && $WITHOUT_NETWORK -ne 1) ]]; then
    # `--with-network` over a non-network binary is allowed but
    # warned — relaxing the sandbox without any network user
    # widens the attack surface for no operational gain. Mirror
    # the eBPF gate's verify-features pattern except as a warn
    # rather than a hard error (operators may install the
    # drop-in ahead of a rebuild, which is a legitimate flow).
    if [[ $WITH_NETWORK -eq 1 && $NEEDS_NETWORK -eq 0 ]]; then
        echo "note: --with-network passed but installed binary doesn't advertise" >&2
        echo "      osv-live or atoms-fetch via --print-features. Drop-in will be" >&2
        echo "      installed anyway, but no daemon code uses it currently." >&2
    fi
    install -d -o root -g root -m 0755 "$EBPF_DROPIN_DIR"
    cat > "$NETWORK_DROPIN_FILE.tmp.$$" <<'EOF'
# atty-guard network drop-in. Generated by `install.sh` when the
# binary was built with `osv-live` or `atoms-fetch` features
# (auto-detected via --print-features), or when the operator
# passed --with-network explicitly. Relaxes the baseline unit's
# PrivateNetwork=yes + RestrictAddressFamilies=AF_UNIX so outbound
# HTTPS to OSV.dev and the atom-corpus sources can resolve.
#
# Remove this file to revert to the network-isolated baseline:
#   sudo ./contrib/install.sh --without-network
[Service]
PrivateNetwork=no
# Clear + re-add — systemd's directive doesn't "extend" when set
# twice; the drop-in's value replaces the baseline's `AF_UNIX`.
# AF_INET / AF_INET6 are the only families ureq + rustls need.
RestrictAddressFamilies=
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
EOF
    mv -f "$NETWORK_DROPIN_FILE.tmp.$$" "$NETWORK_DROPIN_FILE"
    chmod 0644 "$NETWORK_DROPIN_FILE"
    if [[ $WITH_NETWORK -eq 1 ]]; then
        echo "installed $NETWORK_DROPIN_FILE (--with-network)"
    else
        echo "installed $NETWORK_DROPIN_FILE (auto: binary has osv-live or atoms-fetch)"
    fi
elif [[ $WITHOUT_NETWORK -eq 1 ]]; then
    if [[ -f "$NETWORK_DROPIN_FILE" ]]; then
        rm -f "$NETWORK_DROPIN_FILE"
        echo "removed $NETWORK_DROPIN_FILE (--without-network)"
        rmdir "$EBPF_DROPIN_DIR" 2>/dev/null || true
    else
        echo "note: no network drop-in at $NETWORK_DROPIN_FILE — nothing to remove."
    fi
elif [[ -f "$NETWORK_DROPIN_FILE" ]]; then
    echo "note: existing network drop-in at $NETWORK_DROPIN_FILE left in place."
    echo "      pass --with-network to re-confirm, --without-network to remove."
fi

systemctl daemon-reload
systemctl enable --now atty-guard.service
# `enable --now` doesn't restart an already-active service, so a
# drop-in change (ebpf.conf or network.conf added / removed)
# wouldn't take effect until the next manual restart. `try-restart`
# is a no-op when the unit is inactive and a clean restart when
# it's running — re-running the installer now applies any drop-in
# changes immediately.
systemctl try-restart atty-guard.service
echo
systemctl --no-pager --lines=5 status atty-guard.service || true
echo
echo "atty-guard is up. To let your user account talk to the daemon:"
echo
echo "  sudo usermod -aG atty \$USER"
echo "  # log out + back in (or 'newgrp atty' for a single shell)"
echo
echo "Threat-model note: members of the 'atty' group can connect to"
echo "the daemon's UDS socket. They can issue classify requests AND"
echo "introspect their own per-UID trust state (atoms / URLs / trust"
echo "hashes) via 'atty-guard session list' or GetThreatLevel for"
echo "their own PIDs. They CANNOT touch other users' state — the"
echo "daemon's SO_PEERCRED + pid-owner gates restrict every mutating"
echo "and cross-UID read RPC to root (sudo) or the owning UID."
echo "Add ONLY the user accounts that should be able to run atty,"
echo "and treat the 'atty' group as 'trusted to query the local"
echo "classifier' rather than 'arbitrary local users'."
echo
echo "Then set 'daemon_socket_path' in src/config.zig:"
echo
echo "  .daemon_socket_path = \"/run/atty-guard/atty-guard.sock\","
echo
echo "Rebuild atty with the new socket path (make build-atty)."
