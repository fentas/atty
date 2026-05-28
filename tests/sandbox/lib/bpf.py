"""BPF LSM availability probe for sandbox scenarios.

eBPF scenarios are inherently kernel-conditional — the LSM hook
that atty-guard installs (`lsm/bprm_check_security`) needs the
kernel to have BPF LSM enabled at boot. GH-hosted ubuntu runners
historically ship without it; the same scenarios shouldn't fail
loudly on those runners, they should skip with a clear message.

Split into two probes so scenarios can distinguish "kernel doesn't
support this" (true skip) from "container forgot the bind mount"
(scenario bug, should fail loudly).
"""
from __future__ import annotations

import sys
from pathlib import Path


_LSM_FILE = Path("/sys/kernel/security/lsm")


def securityfs_available() -> bool:
    """True iff securityfs is actually mounted at
    `/sys/kernel/security`.

    The bare directory can exist without securityfs mounted (the
    kernel pre-creates the mountpoint), so an `is_dir()` check
    isn't enough to distinguish "mount missing" from "kernel
    lacks BPF LSM". Authoritative test: parse /proc/self/mounts
    for a securityfs entry at the path. Fall back to the lsm
    file's reachability when /proc/self/mounts is restricted.
    """
    mountpoint = str(_LSM_FILE.parent)
    try:
        with open("/proc/self/mounts") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 3 and parts[1] == mountpoint and parts[2] == "securityfs":
                    return True
    except OSError:
        pass
    try:
        return _LSM_FILE.is_file()
    except OSError:
        return False


def kernel_supports_bpf_lsm() -> bool:
    """True iff securityfs is available AND BPF is in the LSM
    list. `/sys/kernel/security/lsm` is the kernel reporting
    which Security Modules are active; without 'bpf' in that
    list, attaching a `lsm/*` BPF program fails with EINVAL.
    Returns False on any OSError reading the file — a permission
    denied (securityfs mounted but not readable in the container)
    falls into the same "can't tell" bucket as missing.
    """
    if not securityfs_available():
        return False
    try:
        return "bpf" in _LSM_FILE.read_text()
    except OSError:
        return False


def skip_if_no_bpf_lsm(scenario_name: str) -> None:
    """Print a SKIP/FAIL line and exit when BPF LSM is unavailable.

    Three branches, each with a tailored message so the next-level
    cause is visible without rereading the source:
    - securityfs not mounted → loud FAIL (docker.json bug).
    - lsm file unreadable (PermissionError / similar OSError) →
      loud FAIL (the mount made it through but bind-mounted ro
      with broken perms, or the container's caps don't allow the
      read — both are container-side bugs).
    - lsm file readable but no 'bpf' → clean SKIP (kernel
      limitation, scenario can't run).
    """
    if not securityfs_available():
        print(f"FAIL: {scenario_name} — securityfs not mounted at "
              f"{_LSM_FILE.parent}. Add to scenario's docker.json: "
              '{"volumes": [{"src": "/sys/kernel/security", '
              '"dst": "/sys/kernel/security"}]}', file=sys.stderr)
        sys.exit(1)
    try:
        contents = _LSM_FILE.read_text()
    except OSError as e:
        print(f"FAIL: {scenario_name} — {_LSM_FILE} unreadable "
              f"({e}). securityfs is mounted but the lsm file "
              "isn't accessible — check the container's bind-mount "
              "permissions / caps.", file=sys.stderr)
        sys.exit(1)
    if "bpf" not in contents:
        print(f"SKIP: {scenario_name} — host kernel lacks BPF LSM "
              f"({_LSM_FILE} does not contain 'bpf'). Build kernel "
              "with CONFIG_BPF_LSM=y AND set lsm=…,bpf in cmdline.")
        sys.exit(0)
